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
      return if existing

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

      Products::ExtendedAttributesFetchService.fetch_for_product(
        child,
        results_jsonl_row: nil,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true,
        strip_listing_relations: true
      )

      child.reload
      if Array(child.images).compact.reject(&:blank?).any?
        ImageDownloader.sync_product_images(child)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn "IncludedProductsBootstrapService: article=#{article} parent=#{parent.sku}: #{e.message}"
    rescue StandardError => e
      Rails.logger.error "IncludedProductsBootstrapService: article=#{article} parent=#{parent.sku}: #{e.class} #{e.message}"
    end
  end
end
