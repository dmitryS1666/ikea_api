# frozen_string_literal: true

require "json"
require "digest"
require "set"
require "fileutils"

BATCH_SIZE = ENV.fetch("BATCH_SIZE", 200).to_i
APPLY_MODE = ENV["APPLY"].to_s == "1"
REPORT_PATH = Rails.root.join("tmp", "cleanup_all_product_images_report.json")
DETAILS_PATH = Rails.root.join("tmp", "cleanup_all_product_images_details.jsonl")

def normalize_array(value)
  case value
  when Array
    value.map(&:to_s).map(&:strip).reject(&:blank?)
  when String
    begin
      parsed = JSON.parse(value)
      parsed.is_a?(Array) ? parsed.map(&:to_s).map(&:strip).reject(&:blank?) : []
    rescue JSON::ParserError
      []
    end
  else
    []
  end
end

def normalize_local_path(path)
  "/" + path.to_s.strip.sub(%r{\A/+}, "")
end

def full_path(path)
  Rails.root.join("public", path.to_s.sub(%r{\A/+}, "")).to_s
end

def image_ok_basic?(path)
  file = full_path(path)

  return [false, "missing"] unless File.exist?(file)
  return [false, "not_file"] unless File.file?(file)
  return [false, "empty"] unless File.size(file).to_i > 0

  header = File.binread(file, 16) rescue nil
  return [false, "unreadable"] if header.blank?

  jpeg = header.bytes.first(2) == [0xFF, 0xD8]
  png  = header.bytes.first(8) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  webp = header.bytesize >= 12 && header[0, 4] == "RIFF" && header[8, 4] == "WEBP"
  gif  = header.start_with?("GIF8")

  return [true, "ok"] if jpeg || png || webp || gif

  [false, "unknown_signature"]
end

def sha256_for(path)
  Digest::SHA256.file(full_path(path)).hexdigest
rescue
  nil
end

def local_images_attr_type
  Product.type_for_attribute("local_images").type
end

def serialize_local_images(paths)
  if [:json, :jsonb].include?(local_images_attr_type)
    paths
  else
    paths.to_json
  end
end

scope = Product.where.not(local_images: nil)
               .where("local_images != '' AND local_images != '[]' AND local_images != 'null'")

total_products = scope.count
puts "Products to scan: #{total_products}"
puts "Mode: #{APPLY_MODE ? 'APPLY' : 'DRY RUN'}"
puts "Batch size: #{BATCH_SIZE}"

# ---- PASS 1: build cleanup plans + final path usage map ----

final_path_refcounts = Hash.new(0)
plans = []

summary = {
  mode: APPLY_MODE ? "apply" : "dry_run",
  scanned_products: 0,
  changed_products: 0,
  unchanged_products: 0,
  total_raw_paths: 0,
  total_final_paths: 0,
  broken_paths_removed: 0,
  duplicate_paths_removed: 0,
  duplicate_content_removed: 0,
  invalid_json_products: 0,
  disk_delete_candidates: 0,
  disk_deleted: 0,
  disk_delete_missing: 0,
  disk_delete_errors: 0,
  started_at: Time.current.iso8601
}

FileUtils.mkdir_p(Rails.root.join("tmp"))
File.write(DETAILS_PATH, "")

scope.find_each(batch_size: BATCH_SIZE) do |product|
  raw_value = product.local_images
  raw_paths = normalize_array(raw_value)
  normalized_paths = raw_paths.map { |p| normalize_local_path(p) }

  summary[:scanned_products] += 1
  summary[:total_raw_paths] += normalized_paths.size

  rows = normalized_paths.map do |path|
    ok, reason = image_ok_basic?(path)
    {
      path: path,
      ok: ok,
      reason: reason,
      sha256: (sha256_for(path) if ok)
    }
  end

  broken = rows.reject { |r| r[:ok] }

  seen_path = Set.new
  seen_sha = Set.new
  final_paths = []

  duplicate_path_removed = 0
  duplicate_content_removed = 0

  rows.each do |row|
    unless row[:ok]
      next
    end

    if seen_path.include?(row[:path])
      duplicate_path_removed += 1
      next
    end

    if row[:sha256].present? && seen_sha.include?(row[:sha256])
      duplicate_content_removed += 1
      next
    end

    final_paths << row[:path]
    seen_path << row[:path]
    seen_sha << row[:sha256] if row[:sha256].present?
  end

  removed_paths = normalized_paths - final_paths
  changed = normalized_paths != final_paths

  final_paths.uniq.each { |path| final_path_refcounts[path] += 1 }

  plan = {
    product_id: product.id,
    sku: product.sku,
    name_ru: product.name_ru,
    raw_count: normalized_paths.size,
    final_count: final_paths.size,
    changed: changed,
    broken_removed_count: broken.size,
    duplicate_path_removed_count: duplicate_path_removed,
    duplicate_content_removed_count: duplicate_content_removed,
    removed_paths: removed_paths,
    final_paths: final_paths
  }

  plans << plan

  summary[:changed_products] += 1 if changed
  summary[:unchanged_products] += 1 unless changed
  summary[:total_final_paths] += final_paths.size
  summary[:broken_paths_removed] += broken.size
  summary[:duplicate_paths_removed] += duplicate_path_removed
  summary[:duplicate_content_removed] += duplicate_content_removed

  File.open(DETAILS_PATH, "a") { |f| f.puts(plan.to_json) }
end

puts "Pass 1 complete"
puts "Changed products: #{summary[:changed_products]}"
puts "Broken to remove: #{summary[:broken_paths_removed]}"
puts "Duplicate path to remove: #{summary[:duplicate_paths_removed]}"
puts "Duplicate content to remove: #{summary[:duplicate_content_removed]}"

# ---- PASS 2: apply DB changes + collect safe disk deletions ----

paths_to_delete = Set.new

plans.each do |plan|
  next unless plan[:changed]

  product = Product.find(plan[:product_id])

  if APPLY_MODE
    product.update_column(:local_images, serialize_local_images(plan[:final_paths]))
  end

  plan[:removed_paths].each do |path|
    paths_to_delete << path if final_path_refcounts[path].zero?
  end
end

summary[:disk_delete_candidates] = paths_to_delete.size

puts "DB pass complete"
puts "Safe disk delete candidates: #{summary[:disk_delete_candidates]}"

# ---- PASS 3: delete orphaned files from disk ----

if APPLY_MODE
  paths_to_delete.each do |path|
    file = full_path(path)

    begin
      if File.exist?(file)
        File.delete(file)
        summary[:disk_deleted] += 1
      else
        summary[:disk_delete_missing] += 1
      end
    rescue => e
      summary[:disk_delete_errors] += 1
      File.open(DETAILS_PATH, "a") do |f|
        f.puts({
          type: "disk_delete_error",
          path: path,
          file: file,
          error: "#{e.class}: #{e.message}"
        }.to_json)
      end
    end
  end
end

summary[:finished_at] = Time.current.iso8601

File.write(REPORT_PATH, JSON.pretty_generate(summary))

puts
puts "Done."
puts "Report:  #{REPORT_PATH}"
puts "Details: #{DETAILS_PATH}"
puts JSON.pretty_generate(summary)
