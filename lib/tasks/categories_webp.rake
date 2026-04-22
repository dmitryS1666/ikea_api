# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "uri"
require "pathname"
require "tempfile"

namespace :categories do
  desc "Convert Category.icon (ActiveStorage) JPG/JPEG/PNG to WEBP"
  task convert_icons_webp: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
    ikea_category_id = ENV["IKEA_CATEGORY_ID"].to_s.strip.presence
    limit = ENV["LIMIT"].to_i
    quality = ENV.fetch("QUALITY", "82").to_i

    scope = Category.all
    scope = scope.where(ikea_id: ikea_category_id) if ikea_category_id.present?

    stdout, stderr, status = Open3.capture3("cwebp", "-version")
    unless status.success?
      abort("cwebp is not available. Install first: sudo apt install webp. Details: #{stderr.presence || stdout}")
    end

    supported_content_types = %w[image/jpeg image/jpg image/png].freeze
    supported_exts = %w[.jpg .jpeg .png].freeze

    processed = 0
    converted = 0
    skipped = 0
    errors = 0

    scope.find_each(batch_size: 200) do |category|
      break if limit.positive? && processed >= limit
      processed += 1

      unless category.icon.attached?
        skipped += 1
        puts "[SKIP] ikea_id=#{category.ikea_id} no icon attached"
        next
      end

      blob = category.icon.blob
      ext = File.extname(blob.filename.to_s).downcase

      if blob.content_type.to_s == "image/webp" || ext == ".webp"
        skipped += 1
        puts "[SKIP] ikea_id=#{category.ikea_id} already webp"
        next
      end

      unless supported_content_types.include?(blob.content_type.to_s) || supported_exts.include?(ext)
        skipped += 1
        puts "[SKIP] ikea_id=#{category.ikea_id} unsupported content_type=#{blob.content_type} ext=#{ext}"
        next
      end

      base_name = blob.filename.base.to_s
      target_filename = "#{base_name}.webp"

      if dry_run
        converted += 1
        puts "[DRY] ikea_id=#{category.ikea_id} #{blob.filename} -> #{target_filename}"
        next
      end

      source_tmp = nil
      target_tmp = nil
      begin
        source_tmp = Tempfile.new(["category_icon_#{category.ikea_id}", ext.presence || ".img"])
        source_tmp.binmode
        source_tmp.write(blob.download)
        source_tmp.flush

        target_tmp = Tempfile.new(["category_icon_#{category.ikea_id}", ".webp"])
        target_tmp.close

        c_stdout, c_stderr, c_status = Open3.capture3(
          "cwebp", "-q", quality.clamp(1, 100).to_s, "-m", "6", "-af", "-sharp_yuv", "-mt", source_tmp.path, "-o", target_tmp.path
        )
        unless c_status.success? && File.exist?(target_tmp.path) && File.size?(target_tmp.path)
          raise "cwebp failed: #{c_stderr.presence || c_stdout || 'unknown error'}"
        end

        old_attachment = category.icon.attachment
        category.icon.attach(
          io: File.open(target_tmp.path, "rb"),
          filename: target_filename,
          content_type: "image/webp"
        )
        old_attachment&.purge_later

        converted += 1
        puts "[OK] ikea_id=#{category.ikea_id} -> #{target_filename}"
      rescue StandardError => e
        errors += 1
        puts "[ERROR] ikea_id=#{category.ikea_id} #{e.class}: #{e.message}"
      ensure
        source_tmp&.close!
        target_tmp&.close!
      end
    end

    puts
    puts "=== categories:convert_icons_webp ==="
    puts "dry_run:   #{dry_run}"
    puts "processed: #{processed}"
    puts "converted: #{converted}"
    puts "skipped:   #{skipped}"
    puts "errors:    #{errors}"
  end
end
