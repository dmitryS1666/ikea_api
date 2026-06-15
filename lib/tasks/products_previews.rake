# frozen_string_literal: true

namespace :products do
  desc "Generate listing preview images (_preview.webp) for product images in public/images/products"
  task generate_previews: :environment do
    sku = ENV["SKU"]
    limit = ENV["LIMIT"]&.to_i
    force = ActiveModel::Type::Boolean.new.cast(ENV.fetch("FORCE", "false"))

    source_paths =
      if sku.present?
        job = GenerateProductImagePreviewsJob.new
        job.send(:collect_source_paths, sku: sku)
      else
        Dir.glob(Rails.public_path.join("images/products/**/*.webp").to_s)
           .reject { |path| ProductLocalImages.preview_path?(path) }
           .select { |path| File.file?(path) && File.size(path).positive? }
           .sort
      end

    source_paths = source_paths.first(limit) if limit.present? && limit.positive?

    generated = 0
    skipped = 0
    errors = 0

    source_paths.each do |source_path|
      result = Products::GenerateImagePreviewService.new(source_path: source_path, force: force).call

      if result.error.present?
        errors += 1
        puts "[ERROR] #{source_path}: #{result.error}"
      elsif result.generated
        generated += 1
        puts "[OK] #{source_path}"
      else
        skipped += 1
      end
    end

    puts
    puts "=== PRODUCT IMAGE PREVIEWS ==="
    puts "processed: #{source_paths.size}"
    puts "generated: #{generated}"
    puts "skipped:   #{skipped}"
    puts "errors:    #{errors}"
  end
end
