# frozen_string_literal: true

namespace :products do
  desc "Convert product local_images to webp via cwebp"
  task convert_webp: :environment do
    dry_run    = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
    sku        = ENV["SKU"]
    limit      = ENV["LIMIT"]&.to_i
    quality    = ENV.fetch("QUALITY", 82).to_i
    batch_size = ENV.fetch("BATCH_SIZE", 100).to_i

    scope = Product
      .where.not(local_images: [nil, "", "[]"])
      .where("local_images LIKE ? OR local_images LIKE ?", "%.jpg%", "%.jpeg%")
    scope = scope.where(sku: sku) if sku.present?
    scope = scope.limit(limit) if limit.present? && limit.positive?

    logger = Logger.new(Rails.root.join("log", "convert_local_images_to_webp.log"), 10, 50.megabytes)
    logger.level = Logger::INFO

    result = Products::ConvertLocalImagesToWebpService.new(
      scope: scope,
      dry_run: dry_run,
      quality: quality,
      batch_size: batch_size,
      logger: logger
    ).call

    puts
    puts "=== WEBP CONVERSION RESULT ==="
    puts "processed_products: #{result.processed_products}"
    puts "updated_products:   #{result.updated_products}"
    puts "processed_images:   #{result.processed_images}"
    puts "converted_images:   #{result.converted_images}"
    puts "skipped_images:     #{result.skipped_images}"
    puts "deleted_originals:  #{result.deleted_originals}"
    puts "errors_count:       #{result.errors.size}"
    puts "error_skus_count:   #{result.error_skus.uniq.size}"
    puts "skipped_skus_count: #{result.skipped_skus.uniq.size}"

    if result.error_skus.any?
      puts
      puts "Broken SKU:"
      result.error_skus.uniq.each { |item| puts "- #{item}" }
    end

    if result.skipped_skus.any?
      puts
      puts "Skipped SKU:"
      result.skipped_skus.uniq.each { |item| puts "- #{item}" }
    end

    report = {
      dry_run: dry_run,
      quality: quality,
      batch_size: batch_size,
      processed_products: result.processed_products,
      updated_products: result.updated_products,
      processed_images: result.processed_images,
      converted_images: result.converted_images,
      skipped_images: result.skipped_images,
      deleted_originals: result.deleted_originals,
      error_skus: result.error_skus.uniq,
      skipped_skus: result.skipped_skus.uniq,
      errors: result.errors
    }

    File.write(
      Rails.root.join("tmp", "webp_conversion_report.json"),
      JSON.pretty_generate(report)
    )

    puts
    puts "Log file:    #{Rails.root.join('log', 'convert_local_images_to_webp.log')}"
    puts "JSON report: #{Rails.root.join('tmp', 'webp_conversion_report.json')}"
  end
end

# sudo apt install webp