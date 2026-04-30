# frozen_string_literal: true

module Products
  # Дочерние позиции набора: связь только в `parent.included_products` (JSON на родителе).
  # Для отсутствующих в БД артикулов создаём полную карточку: LT при наличии, иначе PL, без variants/related.
  # В категорию (CategoryProduct) такие строки не добавляем — они не из листинга PL.
  class IncludedProductsBootstrapService
    def self.ensure!(parent)
      new(parent: parent).ensure!
    end

    def initialize(parent:)
      @parent = parent
    end

    def ensure!
      articles.each { |article| ensure_article!(article) }
    end

    private

    attr_reader :parent

    def articles
      Array(parent.included_products).filter_map { |entry| normalize_article(entry) }.uniq
    end

    def normalize_article(entry)
      token = entry.is_a?(Hash) ? (entry["sku"] || entry[:sku] || entry["item_no"] || entry[:item_no]) : entry
      s = token.to_s.gsub(/\D/, "")
      s if s.match?(/\A\d{8}\z/)
    end

    def ensure_article!(article)
      return if article.blank?

      existing = Products::ListingSkuResolver.find_product(article) ||
        Product.find_by(item_no: article)
      if existing
        enrich_product!(existing)
        return
      end

      listing_sku = "s#{article}"
      url = "https://www.ikea.com/pl/pl/p/-#{article}/"

      child = Product.create!(
        sku: listing_sku,
        item_no: article,
        url: url,
        name: "IKEA #{article}",
        category_id: nil,
        variants: [],
        related_products: [],
        included_products: [],
        images: [],
        quantity: 0
      )

      enrich_product!(child)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn "IncludedProductsBootstrapService: article=#{article} parent=#{parent.sku}: #{e.message}"
    rescue StandardError => e
      Rails.logger.error "IncludedProductsBootstrapService: article=#{article} parent=#{parent.sku}: #{e.class} #{e.message}"
    end

    def enrich_product!(product)
      return unless incomplete_product?(product)

      Products::ExtendedAttributesFetchService.fetch_for_product(
        product,
        results_jsonl_row: nil,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true,
        strip_listing_relations: true
      )

      product.reload
      return unless Array(product.images).compact.reject(&:blank?).any?

      ImageDownloader.sync_product_images(product)
    end

    def incomplete_product?(product)
      return true if product.price.blank? || product.price.to_f <= 0
      return true if product.weight.blank? && product.dimensions.blank?
      return true if product.materials.blank? && poor_full_attributes?(product)
      return true if product.content.to_s.strip.blank? && product.short_description.to_s.strip.blank?
      return true if placeholder_name?(product)

      false
    end

    def poor_full_attributes?(product)
      fa = product.full_attributes
      return true unless fa.is_a?(Hash)

      fa = fa.deep_stringify_keys
      detailed = fa["detailed_info"]
      return false if detailed.is_a?(Hash) && detailed.any?

      skip = %w[measurements_modal product_details_modal measurements_modal_extracted_at product_details_modal_extracted_at]
      fa.except(*skip).blank?
    end

    def placeholder_name?(product)
      product.name.to_s.match?(/\AIKEA\s+(s?)\d{8}\z/i)
    end
  end
end
