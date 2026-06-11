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
      :products_data,
      :snapshot,
      :filters_snapshot,
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
      snapshot = storage_snapshot(build_products_snapshot(products))
      filters = storage_snapshot(build_filters_snapshot(products))
      changed = snapshot != page.products_snapshot || filters != Array.wrap(page.filters_snapshot)

      if persist
        page.update!(snapshot_attributes(snapshot, filters, changed: changed))
      end

      result(products, snapshot, filters, changed)
    end

    def preview
      products = matching_products.to_a
      snapshot = storage_snapshot(build_products_snapshot(products))
      filters = storage_snapshot(build_filters_snapshot(products))

      result(
        products,
        snapshot,
        filters,
        snapshot != page.products_snapshot || filters != Array.wrap(page.filters_snapshot)
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
      scope.includes(:category, :categories, :category_products, :seo_meta)
    end

    def direct_category_ikea_ids
      @direct_category_ikea_ids ||= Array(config["category_ids"] || config[:category_ids])
                                  .map(&:to_s)
                                  .map(&:strip)
                                  .reject(&:blank?)
                                  .uniq
    end

    def category_ikea_ids
      @category_ikea_ids ||= direct_category_ikea_ids.flat_map { |id| Category.self_and_descendant_ikea_ids_for(id) }.uniq
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

    def snapshot_attributes(snapshot, filters, changed:)
      attrs = {
        products_snapshot: snapshot,
        filters_snapshot: filters,
        products_count: products_count_from_snapshot(snapshot),
        last_generated_at: Time.current,
        last_products_updated_at: Product.maximum(:updated_at)
      }

      # SEO-safe правило: не удаляем страницу и не снимаем published, но закрываем от индексации,
      # если опубликованная подборка стала пустой.
      attrs[:indexable] = false if attrs[:products_count].zero? && page.published?

      attrs
    end

    def build_products_snapshot(products)
      ProductTeaserSerializer.new(products, {
        params: serializer_params(products),
        meta: serializer_meta(products)
      }).serializable_hash
    end

    def serializer_params(products)
      promos = active_promos

      {
        favorite_skus: [],
        active_promos: promos,
        promo_applicability: promo_applicability(products, promos),
        rates: exchange_rates,
        calculator_settings: calculator_settings
      }
    end

    def serializer_meta(products)
      {
        total: products.size,
        page: 1,
        per_page: limit,
        total_pages: products.empty? ? 0 : 1,
        default_sort: sort_option
      }
    end

    def products_count_from_snapshot(snapshot)
      Array.wrap(snapshot["data"] || snapshot[:data]).size
    end

    def products_data_from_snapshot(snapshot)
      Array.wrap(snapshot["data"] || snapshot[:data])
    end

    def active_promos
      @active_promos ||= PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
    end

    def promo_applicability(products, promos)
      Array(products).each_with_object({}) do |product, memo|
        cat_ids = ([product.category_id] + product.category_products.map(&:category_id)).compact.uniq
        memo[product.sku] = promos.select { |promo| promo.applies_to_sku?(product.sku, cat_ids) }
      end
    end

    def exchange_rates
      @exchange_rates ||= {
        eur: ExchangeRate.fetch_or_create("EUR")&.rate_per_unit,
        pln: ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
      }
    end

    def calculator_settings
      @calculator_settings ||= {
        "show_delivery_block_global" => CalculatorSetting.get("show_delivery_block_global"),
        "show_reviews_block_global" => CalculatorSetting.get("show_reviews_block_global"),
        "show_tips_block_global" => CalculatorSetting.get("show_tips_block_global"),
        "default_delivery_days" => CalculatorSetting.get("default_delivery_days"),
        "exchange_rate_buffer" => CalculatorSetting.get("exchange_rate_buffer")
      }
    end

    def build_filters_snapshot(products)
      filters = filter_categories(products).flat_map(&:display_filters_for_api)
      merge_filters(filters)
    end

    def filter_categories(products)
      categories = Category.where(ikea_id: direct_category_ikea_ids).to_a if direct_category_ikea_ids.any?
      categories = Array(categories).compact
      return categories if categories.any?

      category_ids = Array(products).flat_map do |product|
        [product.category_id, *product.category_products.map(&:category_id)]
      end.compact.map(&:to_s).reject(&:blank?).uniq

      Category.where(ikea_id: category_ids).to_a
    end

    def merge_filters(filters)
      by_parameter = {}

      Array(filters).each do |filter|
        next unless filter.is_a?(Hash)

        normalized_filter = filter.deep_stringify_keys
        parameter = normalized_filter["parameter"].to_s
        next if parameter.blank?

        target = by_parameter[parameter] ||= normalized_filter.merge("values" => [])
        target["name"] = normalized_filter["name"] if target["name"].blank? && normalized_filter["name"].present?
        target["values"] = merge_filter_values(target["values"], normalized_filter["values"])
      end

      by_parameter.values.reject { |filter| Array(filter["values"]).empty? }
    end

    def merge_filter_values(existing_values, incoming_values)
      values_by_id = Array(existing_values).index_by { |value| value["id"].to_s }

      Array(incoming_values).each do |value|
        next unless value.is_a?(Hash)

        row = value.deep_stringify_keys
        value_id = row["id"].to_s
        next if value_id.blank?

        if values_by_id.key?(value_id)
          values_by_id[value_id] = merge_filter_value_rows(values_by_id[value_id], row)
        else
          values_by_id[value_id] = row
        end
      end

      values_by_id.values.sort_by { |value| (value["name"].presence || value["id"]).to_s.mb_chars.downcase.to_s }
    end

    def merge_filter_value_rows(left, right)
      left.merge(right) do |key, old_value, new_value|
        key == "count" ? [old_value.to_i, new_value.to_i].max : old_value.presence || new_value
      end
    end

    def storage_snapshot(snapshot)
      JSON.parse(snapshot.to_json)
    end

    def result(products, snapshot, filters, changed)
      Result.new(
        page: page,
        products: products,
        products_data: products_data_from_snapshot(snapshot),
        snapshot: snapshot,
        filters_snapshot: filters,
        products_count: products_count_from_snapshot(snapshot),
        changed: changed
      )
    end
  end
end
