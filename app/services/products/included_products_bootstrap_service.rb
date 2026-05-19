# frozen_string_literal: true

module Products
  # Дочерние позиции набора: связь только в `parent.included_products` (JSON на родителе).
  # Для отсутствующих в БД артикулов создаём полную карточку: LT при наличии, иначе PL, без variants/related.
  # В категорию (CategoryProduct) такие строки не добавляем — они не из листинга PL.
  # Комплектующие без фото на IKEA (placeholder в модалке) тоже создаём и обогащаем — галерея не обязательна.
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
      Products::ArticleNumber.normalize_list(parent.included_products)
    end

    def ensure_article!(article)
      return if article.blank?

      existing =
        Products::ListingSkuResolver.find_product(article) ||
        Product.find_by(item_no: article) ||
        Product.where("regexp_replace(item_no, '[^0-9]', '', 'g') = ?", article).first
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
      result = Products::ExtendedAttributesFetchService.fetch_for_product(
        product,
        results_jsonl_row: nil,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true,
        strip_listing_relations: true,
        bundle_component: true
      )

      product.reload
      sync_local_images_if_present!(product)

      Rails.logger.info(
        "IncludedProductsBootstrapService: parent=#{parent.sku} child=#{product.sku} " \
        "updated=#{result[:updated]} images=#{Array(product.images).compact.size} " \
        "name=#{product.name.to_s.truncate(40)}"
      )
    end

    def sync_local_images_if_present!(product)
      return unless Array(product.images).compact.reject(&:blank?).any?

      ImageDownloader.sync_product_images(product)
    end
  end
end
