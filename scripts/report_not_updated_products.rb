# frozen_string_literal: true

require "json"
require "csv"
require "set"

def clean_sku(value)
  value.to_s.gsub(/\D/, "")
end

def load_skus_from_jsonl(path)
  skus = []
  File.foreach(path) do |line|
    line = line.to_s.strip
    next if line.blank?

    begin
      row = JSON.parse(line)
      sku = clean_sku(row["sku"] || row[:sku])
      skus << sku if sku.present?
    rescue JSON::ParserError
      next
    end
  end
  skus
end

def load_skus_from_json(path)
  raw = JSON.parse(File.read(path))
  rows = raw.is_a?(Array) ? raw : [raw]

  rows.filter_map do |row|
    sku = clean_sku(row["sku"] || row[:sku])
    sku if sku.present?
  end
end

def load_skus_from_csv(path)
  skus = []
  CSV.foreach(path, headers: true) do |row|
    sku = clean_sku(row["sku"] || row[:sku])
    skus << sku if sku.present?
  end
  skus
end

def load_skus(path)
  ext = File.extname(path).downcase

  case ext
  when ".jsonl"
    load_skus_from_jsonl(path)
  when ".json"
    load_skus_from_json(path)
  when ".csv"
    load_skus_from_csv(path)
  else
    # fallback: пробуем как jsonl
    load_skus_from_jsonl(path)
  end
end

def parse_since!(value)
  raise ArgumentError, "ENV['SINCE'] is required. Example: SINCE='2026-03-25 12:00:00'" if value.blank?

  parsed =
    if Time.zone
      Time.zone.parse(value)
    else
      Time.parse(value)
    end

  raise ArgumentError, "Cannot parse SINCE=#{value.inspect}" if parsed.blank?

  parsed
end

file_path = ENV["FILE"].presence || Rails.root.join("products_import.jsonl").to_s
out_path  = ENV["OUT"].presence || Rails.root.join("tmp", "not_updated_products_report.json").to_s
since     = parse_since!(ENV["SINCE"])

unless File.exist?(file_path)
  raise ArgumentError, "Import file not found: #{file_path}"
end

puts "Loading SKUs from: #{file_path}"
raw_skus = load_skus(file_path)
unique_skus = raw_skus.map { |sku| clean_sku(sku) }.reject(&:blank?).uniq

puts "Total unique SKUs in file: #{unique_skus.size}"
puts "Checking products not updated since: #{since}"

products = Product.where(sku: unique_skus).to_a
products_by_sku = products.index_by { |p| clean_sku(p.sku) }

missing_skus = unique_skus.reject { |sku| products_by_sku.key?(sku) }

not_updated_products = products.select do |product|
  product.updated_at.blank? || product.updated_at < since
end

category_cache = {}
grouped = not_updated_products.group_by { |product| product.category_id.to_s.presence || "__no_category__" }

category_groups = grouped.map do |category_ikea_id, grouped_products|
  category =
    if category_ikea_id == "__no_category__"
      nil
    else
      category_cache[category_ikea_id] ||= Category.find_by(ikea_id: category_ikea_id)
    end

  {
    category: {
      name: category&.translated_name.presence || category&.name,
      ikea_id: category&.ikea_id || (category_ikea_id == "__no_category__" ? nil : category_ikea_id),
      id: category&.id
    },
    products: grouped_products.sort_by { |p| [p.name_ru.to_s, p.sku.to_s] }.map do |product|
      {
        product_id: product.id,
        sku: product.sku,
        product_name_ru: product.name_ru,
        updated_at: product.updated_at&.iso8601
      }
    end
  }
end

category_groups.sort_by! do |group|
  [
    group.dig(:category, :name).to_s,
    group.dig(:category, :ikea_id).to_s
  ]
end

report = {
  file_path: file_path,
  since: since.iso8601,
  total_unique_skus_in_file: unique_skus.size,
  found_products_in_db: products.size,
  not_updated_products_count: not_updated_products.size,
  missing_products_count: missing_skus.size,
  categories: category_groups,
  missing_products: missing_skus.sort.map { |sku| { sku: sku } }
}

FileUtils.mkdir_p(File.dirname(out_path))
File.write(out_path, JSON.pretty_generate(report))

puts "Report saved to: #{out_path}"
puts "Found in DB: #{products.size}"
puts "Not updated: #{not_updated_products.size}"
puts "Missing in DB: #{missing_skus.size}"

# SINCE="2026-03-25 12:00:00" bundle exec rails runner script/report_not_updated_products.rb
# FILE=products_import.jsonl SINCE="2026-03-25 12:00:00" OUT=tmp/not_updated_products_report.json bundle exec rails runner script/report_not_updated_products.rb