# frozen_string_literal: true

require "httparty"

module Categories
  # Обновляет Category#available_filters из LT-поиска IKEA.
  # LT выбран как приоритетный источник, потому что он возвращает русские подписи фильтров/значений.
  class LtAvailableFiltersRefreshService
    SEARCH_URL = "https://sik.search.blue.cdtapps.com/lt/lt/search?c=listaf&v=20241114".freeze
    PAGE_SIZE = 24

    REQUIRED_PARAMETERS = Categories::FilterPolicy::REQUIRED_PARAMETERS
    FILTER_PARAMETERS = Categories::FilterPolicy::ALLOWED_PARAMETERS
    PRICE_FILTER_VALUES = [{ "id" => "PRICE_RANGE", "name" => "Цена" }].freeze

    PARAMETER_ALIASES = {
      "f-colour" => "f-colors",
      "f-color" => "f-colors",
      "f-colors" => "f-colors",
      "f-price" => "f-price-buckets",
      "f-price-buckets" => "f-price-buckets",
      "f-price-range" => "f-price-buckets",
      "f-feature" => "f-feature",
      "f-features" => "f-feature",
      "f-function" => "f-feature",
      "f-firmness" => "f-firmness",
      "f-comfort" => "f-firmness",
      "f-number-of-seats" => "f-number-of-seats",
      "f-seats" => "f-number-of-seats",
      "f-shape" => "f-shape",
      "f-material" => "f-material",
      "f-materials" => "f-material",
      "f-material-type" => "f-material",
      "f-material-types" => "f-material",
      "f-main-material" => "f-material",
      "f-primary-material" => "f-material",
      "f-composition" => "f-material",
      "f-fabric" => "f-material",
      "f-size" => "f-size",
      "f-series" => "f-series",
      "f-serie" => "f-series",
      "f-type" => "f-type",
      "f-types" => "f-type",
      "f-product-type" => "f-type",
      "f-product-types" => "f-type",
    }.freeze

    NAME_TO_PARAMETER = {
      "цвет" => "f-colors",
      "цвета" => "f-colors",
      "kolor" => "f-colors",
      "kolory" => "f-colors",
      "цена" => "f-price-buckets",
      "цены" => "f-price-buckets",
      "стоимость" => "f-price-buckets",
      "price" => "f-price-buckets",
      "kaina" => "f-price-buckets",
      "свойства" => "f-feature",
      "характеристики" => "f-feature",
      "особенности" => "f-feature",
      "savуbes" => "f-feature",
      "savybes" => "f-feature",
      "жесткость" => "f-firmness",
      "жесткость матраса" => "f-firmness",
      "tvirtumas" => "f-firmness",
      "количество мест" => "f-number-of-seats",
      "число мест" => "f-number-of-seats",
      "vietu skaicius" => "f-number-of-seats",
      "форма" => "f-shape",
      "forma" => "f-shape",
      "материал" => "f-material",
      "материалы" => "f-material",
      "материал/ы" => "f-material",
      "материал / ы" => "f-material",
      "материал/отделка" => "f-material",
      "материал / отделка" => "f-material",
      "материалы и уход" => "f-material",
      "состав" => "f-material",
      "ткань" => "f-material",
      "тканевые" => "f-material",
      "обивка" => "f-material",
      "чехол" => "f-material",
      "medziaga" => "f-material",
      "medziagos" => "f-material",
      "audinys" => "f-material",
      "sudetis" => "f-material",
      "material" => "f-material",
      "materials" => "f-material",
      "materialy" => "f-material",
      "materiał" => "f-material",
      "materiały" => "f-material",
      "tkanina" => "f-material",
      "sklad" => "f-material",
      "skład" => "f-material",
      "размер" => "f-size",
      "размеры" => "f-size",
      "dydis" => "f-size",
      "серия" => "f-series",
      "серии" => "f-series",
      "serija" => "f-series",
      "kolekcija" => "f-series",
      "тип" => "f-type",
      "типы" => "f-type",
      "тип товара" => "f-type",
      "вид" => "f-type",
      "type" => "f-type",
      "types" => "f-type",
      "tipas" => "f-type",
      "rodzaj" => "f-type",
    }.freeze

    Result = Struct.new(
      :changed,
      :filters_count,
      :values_count,
      :missing_parameters,
      :source,
      keyword_init: true
    )

    def initialize(category, reindex: false, ensure_series: true)
      @category = category
      @reindex = reindex
      @ensure_series = ensure_series
    end

    def call
      raise ArgumentError, "category is required" unless @category

      lt_filters = fetch_lt_filters
      merged_filters = merge_with_existing_required_filters(lt_filters)
      changed = !filters_equal?(@category.available_filters, merged_filters)

      @category.update!(available_filters: merged_filters) if changed

      if @ensure_series
        series_result = Categories::RebuildFseriesAvailableFiltersService.new(
          @category,
          propagate_to_descendants: false
        ).call
        changed ||= series_result.changed
      end

      # Переиндексация нужна не только при изменении JSON фильтров: товары/атрибуты могли обновиться,
      # а набор available_filters остаться прежним.
      ReindexCategoryFiltersJob.perform_later(@category.ikea_id) if @reindex

      current_filters = normalize_filters(@category.reload.available_filters)
      Result.new(
        changed: changed,
        filters_count: current_filters.size,
        values_count: current_filters.sum { |f| Array(f["values"]).size },
        missing_parameters: missing_required_parameters(current_filters),
        source: "lt"
      )
    end

    private

    def fetch_lt_filters
      response = ProxyRotator.with_proxy_retry do |proxy_options|
        HTTParty.post(
          SEARCH_URL,
          body: request_body.to_json,
          headers: request_headers,
          timeout: 30,
          **(proxy_options || {})
        )
      end

      unless response.respond_to?(:success?) && response.success?
        raise "LT filters request failed for category #{@category.ikea_id}: HTTP #{response&.code} #{response&.message}"
      end

      parsed = response.parsed_response
      extracted = extract_filter_hashes(parsed)
      normalize_required_filters(extracted)
    end

    def request_body
      {
        searchParameters: {
          input: @category.ikea_id.to_s,
          type: "CATEGORY"
        },
        isUserLoggedIn: false,
        components: [{
          component: "PRIMARY_AREA",
          columns: 4,
          types: {
            main: "PRODUCT",
            breakouts: ["PLANNER", "LOGIN_REMINDER", "MATTRESS_WARRANTY"]
          },
          filterConfig: { "max-num-filters": 50 },
          sort: "RELEVANCE",
          window: { offset: 0, size: PAGE_SIZE }
        }]
      }
    end

    def request_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Accept-Language" => "ru-RU,ru;q=0.9,lt-LT;q=0.8,lt;q=0.7,en;q=0.6",
        "User-Agent" => ENV.fetch("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
      }
    end

    def extract_filter_hashes(node, found = [])
      case node
      when Hash
        found << node if looks_like_filter?(node)
        node.each_value { |value| extract_filter_hashes(value, found) }
      when Array
        node.each { |item| extract_filter_hashes(item, found) }
      end
      found
    end

    def looks_like_filter?(hash)
      h = hash.stringify_keys
      raw_parameter = h["parameter"] || h["filterParameter"] || h["filterId"] || h["id"]
      values = h["values"] || h["options"] || h["items"] || h["filterValues"]
      values.is_a?(Array) && values.any? && (raw_parameter.present? || filter_name(h).present?)
    end

    def normalize_required_filters(raw_filters)
      by_parameter = {}

      raw_filters.each do |raw|
        h = raw.stringify_keys
        parameter = normalize_parameter(h["parameter"] || h["filterParameter"] || h["filterId"] || h["id"], filter_name(h))
        next if parameter.blank?
        next unless Categories::FilterPolicy.allowed?(parameter, category: @category)

        values = normalize_values(h["values"] || h["options"] || h["items"] || h["filterValues"], parameter: parameter)
        next if values.blank? && !REQUIRED_PARAMETERS.key?(parameter)

        by_parameter[parameter] ||= {
          "parameter" => parameter,
          "name" => FILTER_PARAMETERS.fetch(parameter),
          "values" => []
        }

        by_parameter[parameter]["values"] = merge_values(by_parameter[parameter]["values"], values)
      end

      order_filters(by_parameter.values)
    end

    def normalize_parameter(raw_parameter, raw_name)
      parameter = raw_parameter.to_s.strip
      aliased = PARAMETER_ALIASES[parameter]
      return aliased if aliased.present?
      return parameter if FILTER_PARAMETERS.key?(parameter) || Categories::FilterPolicy.excluded?(parameter, category: @category)

      NAME_TO_PARAMETER[normalize_text(raw_name)]
    end

    def filter_name(hash)
      hash["name"] || hash["label"] || hash["title"] || hash.dig("text", "title")
    end

    def normalize_values(raw_values, parameter: nil)
      return PRICE_FILTER_VALUES.deep_dup if parameter.to_s == "f-price-buckets"

      Array(raw_values).filter_map do |raw|
        next unless raw.is_a?(Hash)

        h = raw.stringify_keys
        id = h["id"].to_s.strip.presence || h["value"].to_s.strip.presence || h["filterValue"].to_s.strip.presence
        name = h["name"].to_s.strip.presence || h["label"].to_s.strip.presence || h["title"].to_s.strip.presence || id
        next if id.blank? || name.blank?

        { "id" => id, "name" => clean_value_name(name) }
      end.uniq { |value| [value["id"], normalize_text(value["name"])] }
    end

    def merge_with_existing_required_filters(lt_filters)
      by_parameter = normalize_filters(@category.available_filters)
        .select { |filter| Categories::FilterPolicy.allowed?(filter["parameter"].to_s, category: @category) }
        .index_by { |filter| filter["parameter"].to_s }

      lt_filters.each do |filter|
        parameter = filter["parameter"].to_s
        existing = by_parameter[parameter]
        by_parameter[parameter] = if existing
          existing.merge(
            "name" => FILTER_PARAMETERS.fetch(parameter),
            "values" => merge_values(Array(existing["values"]), Array(filter["values"]))
          )
        else
          filter
        end
      end

      REQUIRED_PARAMETERS.each do |parameter, title|
        next unless Categories::FilterPolicy.allowed?(parameter, category: @category)

        by_parameter[parameter] ||= {
          "parameter" => parameter,
          "name" => title,
          "values" => normalize_values(nil, parameter: parameter)
        }
      end

      order_filters(by_parameter.values)
    end

    def order_filters(filters)
      filters.sort_by { |filter| Categories::FilterPolicy.order_index(filter["parameter"].to_s) }
    end

    def merge_values(existing_values, incoming_values)
      values = {}
      Array(existing_values).concat(Array(incoming_values)).each do |raw|
        next unless raw.is_a?(Hash)

        value = raw.stringify_keys.slice("id", "name", "label")
        value["id"] = value["id"].to_s.strip
        value["name"] = clean_value_name(value["name"].presence || value["label"].presence || value["id"])
        next if value["id"].blank? || value["name"].blank?

        key = value_key(value)
        values[key] ||= value.slice("id", "name")
      end

      values.values.sort_by { |value| normalize_text(value["name"]) }
    end

    def value_key(value)
      if value["id"].to_s.match?(/\A\d+\z/)
        value["id"].to_s
      else
        normalize_text(value["name"])
      end
    end

    def clean_value_name(value)
      Products::SeriesFilterNormalization.display_name(value).presence || value.to_s.strip
    end

    def missing_required_parameters(filters)
      present = filters.filter_map { |filter| filter["parameter"].presence }.to_set
      REQUIRED_PARAMETERS.keys.reject { |parameter| present.include?(parameter) }
    end

    def normalize_filters(raw)
      Array(raw).compact.filter_map do |filter|
        next unless filter.is_a?(Hash)

        h = filter.deep_stringify_keys
        parameter = normalize_parameter(h["parameter"], h["name"])
        next if parameter.blank?
        next unless Categories::FilterPolicy.allowed?(parameter, category: @category)

        {
          "parameter" => parameter,
          "name" => FILTER_PARAMETERS.fetch(parameter),
          "values" => normalize_values(h["values"], parameter: parameter)
        }
      end
    end

    def filters_equal?(a, b)
      canonical_filters(a) == canonical_filters(b)
    end

    def canonical_filters(filters)
      normalize_filters(filters).map do |filter|
        {
          "parameter" => filter["parameter"],
          "name" => filter["name"],
          "values" => Array(filter["values"]).sort_by { |v| [v["id"].to_s, v["name"].to_s] }
        }
      end.to_json
    end

    def normalize_text(value)
      text = value.to_s.downcase
      replacements = {
        "ą" => "a", "č" => "c", "ć" => "c", "ę" => "e", "ė" => "e", "į" => "i",
        "š" => "s", "ų" => "u", "ū" => "u", "ž" => "z", "ł" => "l", "ń" => "n",
        "ó" => "o", "ś" => "s", "ź" => "z", "ż" => "z", "ä" => "a", "ö" => "o",
        "ü" => "u", "å" => "a", "ё" => "е"
      }
      replacements.each { |from, to| text = text.tr(from, to) }
      text.tr("\u00A0", " ").squeeze(" ").strip
    end
  end
end
