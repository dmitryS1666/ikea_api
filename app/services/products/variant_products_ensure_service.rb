# frozen_string_literal: true

module Products
  # SKU из variants_payload (цвет/размер) — отдельные Product в БД с полной карточкой.
  # Нет строки → создаём заглушку, линкуем в категорию, ставим EnrichVariantProductJob.
  # Есть → при неполной карточке снова ставим джобу догрузки.
  class VariantProductsEnsureService
    PL_STUB_URL = "https://www.ikea.com/pl/pl/p/-%{sku}/"

    def self.ensure!(product, category:)
      new(product: product, category: category).ensure!
    end

    def initialize(product:, category:)
      @product = product
      @category = category
    end

    def ensure!
      return unless @category
      return if @product.variants_payload.blank?

      collect_skus.each { |sku| process_variant_sku(sku) }
    end

    private

    attr_reader :product, :category

    def collect_skus
      from_payload = self.class.variant_skus_from_variants_payload(product.variants_payload)
      from_column = product.normalized_variant_skus.map(&:to_s)
      (from_payload + from_column).uniq.map(&:strip).reject(&:blank?) - [product.sku.to_s]
    end

    def process_variant_sku(listing_sku)
      existing = ListingSkuResolver.find_product(listing_sku)
      if existing
        CategoryProduct.find_or_create_by!(product: existing, category_id: category.ikea_id)
        if incomplete_product?(existing)
          EnrichVariantProductJob.perform_later(sku: existing.sku, category_ikea_id: category.ikea_id)
        end
        return
      end

      stub = create_stub_product(listing_sku)
      return if stub.blank?

      CategoryProduct.find_or_create_by!(product: stub, category_id: category.ikea_id)
      EnrichVariantProductJob.perform_later(sku: stub.sku, category_ikea_id: category.ikea_id)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn "VariantProductsEnsureService sku=#{listing_sku}: #{e.class} #{e.message}"
    end

    def incomplete_product?(p)
      return true if p.price.blank? || p.price.to_f <= 0
      return true if p.weight.blank? && p.dimensions.blank?
      return true if p.materials.blank? && poor_full_attributes?(p)
      return true if placeholder_name?(p)

      false
    end

    def poor_full_attributes?(p)
      fa = p.full_attributes
      return true unless fa.is_a?(Hash)

      fa = fa.deep_stringify_keys
      detailed = fa["detailed_info"]
      return false if detailed.is_a?(Hash) && detailed.any?

      skip = %w[measurements_modal product_details_modal measurements_modal_extracted_at product_details_modal_extracted_at]
      fa.except(*skip).blank?
    end

    def placeholder_name?(p)
      p.name.to_s.match?(/\AIKEA\s+(s?)\d{8}\z/i)
    end

    def create_stub_product(listing_sku)
      sku = listing_sku.to_s.strip
      article = sku.match(/(\d{8})/)&.captures&.first
      if article.blank?
        Rails.logger.warn "VariantProductsEnsureService: skip stub, no 8-digit article in #{sku.inspect}"
        return nil
      end

      url = format(PL_STUB_URL, sku: sku.delete("."))
      Product.create!(
        sku: sku,
        item_no: article,
        name: "IKEA #{sku}",
        price: 0,
        quantity: 0,
        url: url,
        category_id: category.ikea_id
      )
    end

    class << self
      def variant_skus_from_variants_payload(variants_payload)
        raw = variants_payload
        return [] if raw.blank?

        data = JSON.parse(raw.to_s)
        groups = data.is_a?(Array) ? data : [data]
        skus = []
        groups.each do |g|
          next unless g.is_a?(Hash)

          g = g.deep_stringify_keys
          Array(g["data"]).each do |row|
            next unless row.is_a?(Hash)

            row = row.deep_stringify_keys
            item = row["item"]
            next unless item.is_a?(Hash)

            item = item.deep_stringify_keys
            Product.expand_listing_skus_from_raw(item["sku"]).each { |s| skus << s }
          end
        end
        skus.uniq
      rescue JSON::ParserError
        []
      end
    end
  end
end
