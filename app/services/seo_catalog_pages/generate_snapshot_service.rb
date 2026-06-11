# frozen_string_literal: true

module SeoCatalogPages
  class GenerateSnapshotService
    DEFAULT_LIMIT = 60
    MAX_LIMIT = 240
    FILTER_ALIASES = {
      "color" => "f-colors",
      "colors" => "f-colors",
      "material" => "f-materials",
      "materials" => "f-materials",
      "size" => "f-measurement-buckets",
      "sizes" => "f-measurement-buckets"
    }.freeze

    Result = Struct.new(
      :page,
      :products,
      :snapshot,
      :products_count,
      :changed,
      keyword_init: true
    )

    def self.call(page, **options)
      new(page, **options).call
    end

    def initialize(page, limit: nil, persist: true)
      @page = page
      @limit_override = limit
      @persist = persist
    end

    def call
      products = matching_products.to_a
      snapshot = storage_snapshot(build_snapshot(products))
      changed = snapshot != Array.wrap(page.products_snapshot)

      if persist
        page.update!(snapshot_attributes(snapshot, changed: changed))
      end

      Result.new(
        page: page,
        products: products,
        snapshot: snapshot,
        products_count: snapshot.size,
        changed: changed
      )
    end

    def preview
      products = matching_products.to_a
      snapshot = storage_snapshot(build_snapshot(products))

      Result.new(
        page: page,
        products: products,
        snapshot: snapshot,
        products_count: snapshot.size,
        changed: snapshot != Array.wrap(page.products_snapshot)
      )
    end

    private

    attr_reader :page, :limit_override, :persist

    def matching_products
      Products::SearchService
        .new(nil, search_params, base_scope: base_scope, default_sort: sort_option)
        .call
        .distinct
        .limit(limit)
    end

    def base_scope
      scope = Product.active
      scope = scope.in_categories_ikea_ids(category_ikea_ids) if category_ikea_ids.any?
      scope = only_available? ? scope.available_for_listing : scope.with_listing_price
      scope.includes(:category, :category_products)
    end

    def category_ikea_ids
      @category_ikea_ids ||= begin
        ids = Array(config["category_ids"] || config[:category_ids]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        ids.flat_map { |id| Category.self_and_descendant_ikea_ids_for(id) }.uniq
      end
    end

    def search_params
      {
        min_price: config["min_price"] || config[:min_price],
        max_price: config["max_price"] || config[:max_price],
        sort: sort_option,
        filters: normalized_filters
      }
    end

    def normalized_filters
      raw = config["filters"] || config[:filters] || {}
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), memo|
        normalized_key = FILTER_ALIASES.fetch(key.to_s, key.to_s)
        values = Array(value).map(&:to_s).map(&:strip).reject(&:blank?)
        memo[normalized_key] = values if normalized_key.present? && values.any?
      end
    end

    def sort_option
      (config["sort"] || config[:sort]).presence || "popular"
    end

    def only_available?
      raw = config.key?("only_available") ? config["only_available"] : config[:only_available]
      ActiveModel::Type::Boolean.new.cast(raw)
    end

    def limit
      raw = limit_override || config["limit"] || config[:limit] || DEFAULT_LIMIT
      [[raw.to_i, 1].max, MAX_LIMIT].min
    end

    def config
      @config ||= (page.filter_config.presence || {}).deep_stringify_keys
    end

    def snapshot_attributes(snapshot, changed:)
      attrs = {
        products_snapshot: snapshot,
        products_count: snapshot.size,
        last_generated_at: Time.current,
        last_products_updated_at: Product.maximum(:updated_at)
      }

      # SEO-safe правило: не удаляем страницу и не снимаем published, но закрываем от индексации,
      # если опубликованная подборка стала пустой.
      attrs[:indexable] = false if snapshot.empty? && page.published?

      attrs
    end

    def build_snapshot(products)
      products.map { |product| product_payload(product) }
    end

    def product_payload(product)
      {
        id: product.id,
        sku: Product.public_sku(product.sku),
        slug: product.slug,
        name_ru: product.name_ru.to_s.presence || product.name.to_s,
        price_byn: storefront_price_byn(product),
        available: product.available_in_stock?,
        image_url: ProductLocalImages.expand_paths(product.local_images).first,
        badges: product_badges(product)
      }
    end

    def storage_snapshot(snapshot)
      JSON.parse(snapshot.to_json)
    end

    def storefront_price_byn(product)
      price = PriceCalculationService.product_storefront_price_byn(
        product.price.to_f,
        weight_kg: product.packaging_weight_kg.to_f,
        delivery_pln: product.delivery_cost.to_f,
        pln_rate: pln_rate,
        buffer: exchange_rate_buffer
      )

      format("%.2f", price)
    end

    def pln_rate
      @pln_rate ||= ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
    end

    def exchange_rate_buffer
      @exchange_rate_buffer ||= CalculatorSetting.get("exchange_rate_buffer") || PriceCalculationService.exchange_rate_buffer
    end

    def product_badges(product)
      badges = []
      badges << "bestseller" if product.is_bestseller?
      badges << "new" if product.is_new?
      badges << "popular" if product.is_popular?
      badges << "recommended" if product.is_recommended?
      badges
    end
  end
end
