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
      articles = resolve_articles!
      if articles.empty?
        Rails.logger.warn "IncludedProductsBootstrapService: no included articles for parent=#{parent.sku}"
        return
      end

      Rails.logger.info "IncludedProductsBootstrapService: parent=#{parent.sku} ensuring #{articles.size} articles: #{articles.join(', ')}"
      articles.each { |article| ensure_article!(article) }
    end

    private

    attr_reader :parent

    def resolve_articles!
      stored = Products::ArticleNumber.normalize_list(parent.included_products)
      fetched = fetch_included_articles_from_pl!
      list =
        if fetched.size > stored.size
          fetched
        elsif fetched.any?
          (stored + fetched).uniq
        else
          stored
        end

      if list.empty?
        list = Products::ArticleNumber.normalize_list(parent.set_items)
        Rails.logger.info "IncludedProductsBootstrapService: fallback to set_items (#{list.size}) parent=#{parent.sku}" if list.any?
      end

      persist_parent_included!(list) if list.any? && list != stored
      list
    end

    def fetch_included_articles_from_pl!
      url = parent_pl_pip_url
      return [] if url.blank?

      unless PlDetailsFetcher.headless_browser_executable_available?
        Rails.logger.warn "IncludedProductsBootstrapService: Chrome/Chromium unavailable parent=#{parent.sku}"
      end

      list = PlDetailsFetcher.fetch_included_articles(url, scope_sku: parent.sku)
      if list.empty?
        Rails.logger.warn "IncludedProductsBootstrapService: empty included from PL parent=#{parent.sku} url=#{url}"
      end
      list
    rescue StandardError => e
      Rails.logger.error "IncludedProductsBootstrapService: PL fetch failed parent=#{parent.sku}: #{e.class} #{e.message}"
      []
    end

    def parent_pl_pip_url
      article = Products::ArticleNumber.normalize(parent.item_no) ||
                Products::ArticleNumber.normalize(parent.sku)
      return "https://www.ikea.com/pl/pl/p/-#{article}/" if article.present?

      u = parent.url.to_s
      return u if u.include?("/pl/pl/")

      u.gsub(%r{/lt/ru/}, "/pl/pl/").presence
    end

    def persist_parent_included!(list)
      parent.update!(included_products: list)
      parent.reload
    rescue StandardError => e
      Rails.logger.warn "IncludedProductsBootstrapService: failed to save included_products parent=#{parent.sku}: #{e.message}"
    end

    def ensure_article!(article)
      return if article.blank?

      child = find_or_create_child!(article)
      return unless child

      enrich_product!(child)
    rescue StandardError => e
      Rails.logger.error "IncludedProductsBootstrapService: article=#{article} parent=#{parent.sku}: #{e.class} #{e.message}"
    end

    def find_or_create_child!(article)
      existing = find_existing_child(article)
      return existing if existing

      create_child!(article)
    end

    def find_existing_child(article)
      Products::ListingSkuResolver.find_product(article) ||
        Product.find_by(item_no: article) ||
        Product.find_by(sku: "s#{article}") ||
        Product.where("regexp_replace(coalesce(item_no, ''), '[^0-9]', '', 'g') = ?", article).first
    end

    def create_child!(article)
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
      Rails.logger.info "IncludedProductsBootstrapService: created child sku=#{listing_sku} parent=#{parent.sku}"
      child
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn "IncludedProductsBootstrapService: create article=#{article} parent=#{parent.sku}: #{e.message}"
      find_existing_child(article)
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
