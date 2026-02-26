require 'csv'

module Categories
  class ProductImportService
    Result = Struct.new(:imported, :skipped, :errors, :total, :skipped_skus, :error_message, keyword_init: true)

    def initialize(category, file)
      @category = category
      @file = file
    end

    def call
      return Result.new(imported: 0, skipped: 0, errors: 1, total: 0, skipped_skus: [], error_message: "Файл не выбран") unless @file.respond_to?(:path)

      skus = []
      begin
        CSV.foreach(@file.path, headers: false) do |row|
          sku = row[0].to_s.strip
          skus << sku if sku.present?
        end
      rescue CSV::MalformedCSVError => e
        return Result.new(imported: 0, skipped: 0, errors: 1, total: 0, skipped_skus: [], error_message: "Ошибка парсинга CSV: #{e.message}")
      end

      skus.uniq!
      total = skus.size
      
      products = Product.where(sku: skus).to_a
      found_skus = products.map(&:sku)
      skipped_skus = skus - found_skus
      
      imported = 0
      errors = 0
      
      @category.transaction do
        @category.category_products.delete_all
        products.each do |product|
          @category.category_products.create!(product: product)
          imported += 1
        rescue StandardError => e
          Rails.logger.error("[Categories::ProductImportService] sku=#{product.sku} error=#{e.class}: #{e.message}")
          errors += 1
        end
      end

      Result.new(
        imported: imported,
        skipped: skipped_skus.size,
        errors: errors,
        total: total,
        skipped_skus: skipped_skus
      )
    end
  end
end
