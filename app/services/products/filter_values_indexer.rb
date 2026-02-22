module Products
  class FilterValuesIndexer
    BOOLEAN_PARAMS = %w[
      f-top-seller
      f-special-price
      f-new-product
      f-last-chance
    ].freeze

    PARAMETER_KEYS = {
      "f-type" => ["Typ", "Rodzaj"],
      "f-function" => ["Funkcja", "Funkcje"],
      "f-feature" => ["Właściwości", "Cechy", "Funkcje"],
      "f-series" => ["Seria", "Kolekcja"],
      "f-energy-labels" => ["Etykieta energetyczna", "Klasa energetyczna"],
      "f-number-of-cooking-zones" => ["Liczba pól grzewczych", "Liczba stref grzewczych", "Liczba pół grzewczych"],
      "f-colors" => ["Kolor", "Kolory", "Kolorystyka", "Kolor/wykończenie", "Kolor/wykonczenie"],
      "f-material" => ["Materiał", "Materiały", "Materiał/wykończenie", "Materiały i pielęgnacja"],
      "f-materials" => ["Materiał", "Materiały", "Materiał/wykończenie", "Materiały i pielęgnacja"],
      "f-style" => ["Styl", "Styl i wykończenie"],
      "f-room" => ["Pomieszczenie", "Pomieszczenia", "Przeznaczenie"],
      "f-pattern" => ["Wzór", "Wzory"],
      "f-shape" => ["Kształt", "Ksztalt"],
      "f-brand" => ["Marka", "Producent"],
      "f-size" => ["Rozmiar", "Wymiar", "Wymiary"],
      "f-length" => ["Długość", "Dlugosc"],
      "f-width" => ["Szerokość"],
      "f-height" => ["Wysokość"],
      "f-depth" => ["Głębokość"],
      "f-number-of-doors" => ["Liczba drzwi"],
      "f-number-of-drawers" => ["Liczba szuflad"],
      "f-number-of-shelves" => ["Liczba półek"],
      "f-number-of-seats" => ["Liczba miejsc"]
    }.freeze

    MEASUREMENT_KEYS = {
      width: ["Szerokość"],
      height: ["Wysokość"],
      depth: ["Głębokość"],
      volume: ["Pojemność"]
    }.freeze

    def initialize(category)
      @category = category
      @filters = Array(category.available_filters)
    end

    def reindex!
      return if @filters.blank?

      ProductFilterValue.where(category_id: @category.ikea_id).delete_all

      products = @category.products_through_categories
      promo_skus = active_promo_skus(products)

      products.find_each do |product|
        index_product(product, promo_skus: promo_skus)
      end
    end

    def reindex_product(product)
      return if @filters.blank?

      ProductFilterValue.where(category_id: @category.ikea_id, product_id: product.id).delete_all
      index_product(product)
    end

    def index_product(product, promo_skus: nil)
      return if @filters.blank?

      promo_skus ||= active_promo_skus(Product.where(id: product.id))
      values = match_product(product, promo_skus: promo_skus)

      rows = []
      values.each do |parameter, value_ids|
        Array(value_ids).each do |value_id|
          rows << {
            product_id: product.id,
            category_id: @category.ikea_id,
            parameter: parameter,
            value_id: value_id,
            created_at: Time.current,
            updated_at: Time.current
          }
        end
      end

      ProductFilterValue.insert_all(rows) if rows.any?
    end

    private

    def match_product(product, promo_skus:)
      results = Hash.new { |h, k| h[k] = [] }

      @filters.each do |filter|
        parameter = filter["parameter"].to_s
        values = Array(filter["values"])

        if BOOLEAN_PARAMS.include?(parameter)
          results[parameter] << "true" if boolean_filter_match?(parameter, product, promo_skus)
          next
        end

        case parameter
        when "f-measurement-buckets"
          match_measurements(results, parameter, values, product)
        when "f-price-buckets"
          match_price(results, parameter, values, product)
        when "f-ratings"
          match_rating(results, parameter, values, product)
        when "f-series"
          match_series(results, parameter, values, product)
        when "f-number-of-cooking-zones", "f-number-of-doors", "f-number-of-drawers", "f-number-of-shelves", "f-number-of-seats"
          match_number_of_zones(results, parameter, values, product)
        when "f-energy-labels"
          match_textual_parameter(results, parameter, values, product, PARAMETER_KEYS[parameter])
        when "f-type", "f-feature", "f-function", "f-colors", "f-material", "f-materials", "f-style", "f-room", "f-pattern",
             "f-shape", "f-brand", "f-size", "f-length", "f-width", "f-height", "f-depth"
          match_textual_parameter(results, parameter, values, product, PARAMETER_KEYS[parameter])
        else
          match_textual_parameter(results, parameter, values, product, PARAMETER_KEYS[parameter])
        end
      end

      results
    end

    def match_measurements(results, parameter, values, product)
      measurements = extract_measurements(product)
      values.each do |value|
        bucket = parse_measurement_bucket(value["id"])
        next unless bucket

        measure_value = measurements[bucket[:type]]
        next if measure_value.nil?

        if measure_value >= bucket[:min] && measure_value <= bucket[:max]
          results[parameter] << value["id"]
        end
      end
    end

    def match_price(results, parameter, values, product)
      price_cents = price_to_cents(product.price)
      return if price_cents.nil?

      values.each do |value|
        range = parse_price_bucket(value["id"])
        next unless range

        if price_cents >= range[:min] && price_cents <= range[:max]
          results[parameter] << value["id"]
        end
      end
    end

    def match_rating(results, parameter, values, product)
      rating = product.rating_avg || product.rating_weighted
      return if rating.blank?

      values.each do |value|
        threshold = value["id"].to_f
        results[parameter] << value["id"] if rating >= threshold
      end
    end

    def match_series(results, parameter, values, product)
      series_values = attribute_values_for_keys(product, PARAMETER_KEYS["f-series"])
      series_values << product.collection if product.collection.present?

      values.each do |value|
        results[parameter] << value["id"] if text_values_match?(series_values, value["name"])
      end
    end

    def match_number_of_zones(results, parameter, values, product)
      values_from_attrs = attribute_values_for_keys(product, PARAMETER_KEYS[parameter])
      zones = values_from_attrs.map { |val| extract_integer(val) }.compact
      return if zones.empty?

      values.each do |value|
        target = value["id"].to_i
        results[parameter] << value["id"] if zones.any? { |z| z == target }
      end
    end

    def match_textual_parameter(results, parameter, values, product, keys)
      text_values = attribute_values_for_keys(product, keys)
      text_values.concat(extract_features_text(product)) if parameter == "f-feature"
      text_values.concat(attribute_text_pool(product)) if keys.blank?

      values.each do |value|
        target = value["name"].presence || value["id"]
        next if target.blank?

        results[parameter] << value["id"] if text_values_match?(text_values, target)
      end
    end

    def boolean_filter_match?(parameter, product, promo_skus)
      case parameter
      when "f-top-seller"
        product.is_bestseller? || product.is_popular?
      when "f-special-price"
        promo_skus.include?(product.sku)
      when "f-new-product"
        product.created_at.present? && product.created_at >= 30.days.ago
      when "f-last-chance"
        product.quantity.present? && product.quantity <= 10
      else
        false
      end
    end

    def active_promo_skus(scope)
      skus = scope.pluck(:sku).compact
      return [] if skus.empty?

      promo_ids = PromoCodeProduct.where(product_sku: skus).distinct.pluck(:promo_code_id)
      return [] if promo_ids.empty?

      active_promos = PromoCode.where(id: promo_ids).select(&:active_now?)
      return [] if active_promos.empty?

      PromoCodeProduct.where(promo_code_id: active_promos.map(&:id), product_sku: skus)
                      .distinct
                      .pluck(:product_sku)
    end

    def extract_measurements(product)
      attributes = product.full_attributes || {}
      measurements = {}

      MEASUREMENT_KEYS.each do |type, keys|
        keys.each do |key|
          value = attributes[key]
          number = extract_number(value)
          next if number.nil?

          measurements[type] = number
          break
        end
      end

      measurements
    end

    def parse_measurement_bucket(value_id)
      match = value_id.to_s.match(/\A(WIDTH|HEIGHT|DEPTH|VOLUME)_(\d+)_([0-9]+)\z/)
      return nil unless match

      type = match[1].downcase.to_sym
      min = match[2].to_f
      max = match[3].to_f
      max = Float::INFINITY if max >= 9_223_372_036_854_775_807

      { type: type, min: min, max: max }
    end

    def parse_price_bucket(value_id)
      match = value_id.to_s.match(/\APRICE_(\d+)_([0-9]+)\z/)
      return nil unless match

      { min: match[1].to_i, max: match[2].to_i }
    end

    def price_to_cents(price)
      return nil if price.blank?
      (price.to_f * 100).round
    end

    def extract_integer(value)
      return nil if value.blank?
      value.to_s.scan(/\d+/).first&.to_i
    end

    def extract_number(value)
      return nil if value.blank?

      if value.is_a?(Array)
        value.each do |item|
          number = extract_number(item)
          return number if number
        end
        return nil
      end

      if value.is_a?(Hash)
        value.values.each do |item|
          number = extract_number(item)
          return number if number
        end
        return nil
      end

      match = value.to_s.gsub(",", ".").match(/(\d+(\.\d+)?)/)
      match ? match[1].to_f : nil
    end

    def attribute_values_for_keys(product, keys)
      return [] if keys.blank?

      attributes = product.full_attributes || {}
      values = []

      keys.each do |key|
        value = attributes[key]
        values.concat(normalize_value(value))
      end

      values
    end

    def extract_features_text(product)
      return [] if product.features.blank?

      if product.features.is_a?(Array)
        product.features
      else
        product.features.to_s.split("\n")
      end
    end

    def attribute_text_pool(product)
      attributes = product.full_attributes || {}
      pool = []

      attributes.each do |key, value|
        pool << key
        pool.concat(normalize_value(value))
      end

      pool.concat(normalize_value(product.materials)) if product.materials.present?
      pool.concat(normalize_value(product.features)) if product.features.present?
      pool
    end

    def normalize_value(value)
      case value
      when Array
        value.flat_map { |v| normalize_value(v) }
      when Hash
        value.values.flat_map { |v| normalize_value(v) }
      when nil
        []
      else
        [value.to_s]
      end
    end

    def text_values_match?(values, target)
      return false if target.blank?

      target_norm = normalize_text(target)
      values.any? { |value| normalize_text(value).include?(target_norm) }
    end

    def normalize_text(value)
      value.to_s.downcase.tr("\u00A0", " ").squeeze(" ").strip
    end
  end
end
