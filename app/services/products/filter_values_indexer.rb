require "set"

module Products
  class FilterValuesIndexer
    INSERT_BATCH_SIZE = 1_000
    EXCLUDED_PARAMETERS = %w[f-type].freeze

    BOOLEAN_PARAMS = %w[
      f-top-seller
      f-special-price
      f-new-product
      f-last-chance
    ].freeze

    PARAMETER_KEYS = {
      "f-type" => ["Typ", "Rodzaj", "Тип", "Вид"],
      "f-function" => ["Funkcja", "Funkcje", "Функция", "Функции"],
      "f-feature" => ["Właściwości", "Cechy", "Funkcje", "Свойства", "Характеристики", "Особенности", "Функции"],
      "f-series" => ["Seria", "Serie", "Kolekcja", "Kolekcje", "Collection", "Серия", "Коллекция"],
      "f-energy-labels" => ["Etykieta energetyczna", "Klasa energetyczna", "Энергетическая этикетка", "Класс энергопотребления", "Энергетический класс"],
      "f-number-of-cooking-zones" => ["Liczba pól grzewczych", "Liczba stref grzewczych", "Liczba pół grzewczych", "Количество конфорок", "Количество зон нагрева", "Количество варочных зон"],
      "f-colors" => ["Kolor", "Kolory", "Kolorystyka", "Kolor/wyкоńчение", "Kolor/wykonczenie", "Цвет", "Цвета", "Цветовая гамма", "Цвет/отделка"],
      "f-material" => ["Materiał", "Materiały", "Materiał/wykońчение", "Materiały i pielęgnacja", "Материал", "Материалы", "Материал/отделка", "Материалы и уход"],
      "f-materials" => ["Materiał", "Materiały", "Materiał/wykończenie", "Materiały i pielęgnacja", "Материал", "Материалы", "Материал/отделка", "Материалы и уход"],
      "f-style" => ["Styl", "Styl i wykończenie", "Стиль", "Стиль и отделка"],
      "f-room" => ["Pomieszczenie", "Pomieszczenia", "Przeznaczenie", "Помещение", "Помещения", "Назначение"],
      "f-pattern" => ["Wzór", "Wzory", "Узор", "Узоры"],
      "f-shape" => ["Kształt", "Ksztalt", "Форма"],
      "f-brand" => ["Marka", "Producent", "Бренд", "Марка", "Производитель"],
      "f-size" => ["Rozmiar", "Wymiar", "Wymiary", "Wysokość wraz z uchwytem", "Wysokość pod meblem", "Wysokość z poduchami oparcia", "Wysokość łóżka", "Wysokość oparcia", "Wysokość podłokietnika", "Głębokość całkowita po rozłożeniu", "Głębokość siedziska, szezlong", "grubość materaca", "Szerokość siedziska strona lewa", "Obciążenie półki", "Размер", "Габарит", "Габариты", "Размеры"],
      "f-length" => ["Długość", "Dlugosc", "Длина"],
      "f-width" => ["Szerokość", "Szerokość siedziska strona lewa", "Ширина"],
      "f-height" => ["Wysokość", "Wysokość wraz z uchwytem", "Wysokość pod meblem", "Wysokość z poduchami oparcia", "Wysokość łóżka", "Wysokość oparcia", "Wysokość podłokietnika", "Высота"],
      "f-depth" => ["Głębokość", "Głębokość całkowita po rozłożeniu", "Głębokość siedziska, szezlong", "Глубина"],
      "f-number-of-doors" => ["Liczba drzwi", "Количество дверей"],
      "f-number-of-drawers" => ["Liczba szuflad", "Количество ящиков"],
      "f-number-of-shelves" => ["Liczba półek", "Количество полок"],
      "f-number-of-seats" => ["Liczba miejsc", "Количество мест"]
    }.freeze

    MEASUREMENT_KEYS = {
      width: ["Szerokość", "Szerokość siedziska strona lewa", "Ширина"],
      height: ["Wysokość", "Wysokość wraz z uchwytem", "Wysokość pod meblem", "Wysokość z poduchami oparcia", "Wysokość łóżka", "Wysokość oparcia", "Wysokość podłokietnika", "Высота"],
      depth: ["Głębokość", "Głębokość całkowita po rozłożeniu", "Głębokość siedziska, szezlong", "Глубина"],
      length: ["Długość", "Dlugosc", "Длина"],
      diameter: ["Średnica", "Srednica", "Диаметр"],
      volume: ["Pojemność", "Объем", "Объём"]
    }.freeze

    VALUE_TRANSLATIONS = {
      # Цвета
      "белый" => ["biały", "biała", "białe", "białego", "białych", "białym", "white"],
      "черный" => ["czarny", "czarna", "czarne", "czarnego", "czarnych", "czarnym", "black"],
      "бежевый" => ["beżowy", "beżowa", "beżowe", "beżowym", "beige"],
      "серый" => ["szary", "szara", "szare", "szaryм", "grey", "gray"],
      "коричневый" => ["brązowy", "brązowa", "brązowe", "brązowym", "brown"],
      "зеленый" => ["zielony", "zielona", "zielone", "zielonym", "green"],
      "синий" => ["niebieski", "niebiesка", "niebiesкие", "niebiesким", "blue"],
      "оранжевый" => ["pomarańczowy", "pomarańczowa", "pomarańczowe", "pomarańczowym", "orange"],
      "красный" => ["czerwony", "czerwona", "czerwone", "czerwonym", "red"],
      "желтый" => ["żółтый", "żółта", "żółте", "жółтым", "yellow"],
      "розовый" => ["różowy", "różowa", "różowe", "розовым", "pink"],
      "бирюзовый" => ["turkusowy", "turkusowa", "turkusowe", "turkusвым", "turquoise"],
      
      # Материалы
      "дерево" => ["drewno", "drewniany", "lite drewno", "sosna", "dąб", "buk", "brзоза", "wood", "oak", "pine", "birch"],
      "металл" => ["metal", "stal", "stalowa", "aluminium"],
      "стекло" => ["szкło", "szklane", "glass"],
      "пластик" => ["plastik", "tworzywo", "tworzywo polipropylenowe", "polypropylene"],
      "ткань" => ["tkanina", "tekstylia", "bawełна", "poliester", "fabric"],
      
      # Формы
      "круглый" => ["okrąглый", "okrągła", "round"],
      "квадратный" => ["kwadratowy", "kwadratowa", "square"],
      "прямоугольный" => ["prostokątny", "prostokątна", "rectangular"],
      "овальный" => ["owalny", "owalna", "oval"],
      
      # Стили
      "современный" => ["nowoczesny", "współczesny", "modern"],
      "традиционный" => ["tradycyjny", "klasyczny", "traditional", "classic"]
    }.freeze

    # parameters: список id фильтров из available_filters (например %w[f-series f-colors]).
    # nil — переиндексировать все фильтры категории (прежнее поведение).
    def initialize(category, parameters: nil)
      @category = category
      @filters = Array(category.available_filters)
      @parameters_provided = !parameters.nil?
      @parameters = normalize_filter_parameters(parameters)
    end

    def reindex!
      eff = filters_to_apply
      return if eff.blank?

      if selective_mode?
        ProductFilterValue.where(category_id: @category.ikea_id, parameter: @parameters).delete_all
      else
        ProductFilterValue.where(category_id: @category.ikea_id).delete_all
      end

      products = Product.catalog_category_scope(@category.ikea_id)
      promo_skus = active_promo_skus(products).to_set

      rows = []
      products.find_each do |product|
        rows.concat(build_rows_for_product(product, promo_skus: promo_skus, filters: eff))
        flush_rows(rows) if rows.size >= INSERT_BATCH_SIZE
      end

      flush_rows(rows)
    end

    def reindex_product(product)
      eff = filters_to_apply
      return if eff.blank?

      if selective_mode?
        ProductFilterValue.where(category_id: @category.ikea_id, product_id: product.id, parameter: @parameters).delete_all
      else
        ProductFilterValue.where(category_id: @category.ikea_id, product_id: product.id).delete_all
      end

      return unless product.quantity.to_i.positive?

      index_product(product, filters: eff)
    end

    def index_product(product, promo_skus: nil, filters: nil)
      rows = build_rows_for_product(product, promo_skus: promo_skus, filters: filters)
      flush_rows(rows)
    end

    def build_rows_for_product(product, promo_skus: nil, filters: nil)
      filters ||= filters_to_apply
      return [] if filters.blank?

      promo_skus ||= active_promo_skus(Product.where(id: product.id)).to_set
      values = match_product(product, promo_skus: promo_skus, filters: filters)
      rows_for_values(product, values)
    end

    def rows_for_values(product, values)
      now = Time.current

      rows = []
      values.each do |parameter, value_ids|
        Array(value_ids).each do |value_id|
          rows << {
            product_id: product.id,
            category_id: @category.ikea_id,
            parameter: parameter,
            value_id: value_id,
            created_at: now,
            updated_at: now
          }
        end
      end

      rows.uniq { |row| [row[:product_id], row[:category_id], row[:parameter], row[:value_id]] }
    end

    def flush_rows(rows)
      return if rows.blank?

      rows.uniq! { |row| [row[:product_id], row[:category_id], row[:parameter], row[:value_id]] }
      ProductFilterValue.insert_all(rows, unique_by: :index_product_filter_values_unique)
      rows.clear
    end

    private

    def normalize_filter_parameters(parameters)
      Array(parameters)
        .map { |p| p.to_s.strip.presence }
        .compact
        .uniq
        .reject { |parameter| EXCLUDED_PARAMETERS.include?(parameter) }
    end

    def selective_mode?
      @parameters_provided
    end

    def filters_to_apply
      return [] if @filters.blank?

      available = @filters.reject { |f| EXCLUDED_PARAMETERS.include?(f["parameter"].to_s) }
      return available unless selective_mode?
      return [] if @parameters.blank?

      available.select { |f| @parameters.include?(f["parameter"].to_s) }
    end

    def match_product(product, promo_skus:, filters:)
      results = Hash.new { |h, k| h[k] = [] }

      filters.each do |filter|
        parameter = filter["parameter"].to_s
        values = Array(filter["values"])

        next if parameter.blank?
        next if parameter == "f-availability"

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
      grouped_values = Array(values)
        .map { |value| value.is_a?(Hash) ? value.deep_stringify_keys : nil }
        .compact
        .group_by { |value| normalize_series_name(value["name"].presence || value["id"]) }
        .reject { |normalized_name, _| normalized_name.blank? }

      matched_series_names = extract_series_names_from_product(product, grouped_values.keys)
      return if matched_series_names.blank?

      grouped_values.each do |normalized_name, grouped_filter_values|
        next unless matched_series_names.include?(normalized_name)

        grouped_filter_values.each do |value|
          value_id = value["id"].to_s
          next if value_id.blank?

          results[parameter] << value_id
        end
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
      text_values.concat(material_text_pool(product)) if %w[f-material f-materials].include?(parameter)
      text_values.concat(dimension_text_pool(product)) if %w[f-size f-length f-width f-height f-depth].include?(parameter)
      text_values.concat([product.name, product.name_ru, product.small_desc_name].compact) if parameter == "f-type"

      if keys.blank? || text_values.blank?
        text_values.concat(attribute_text_pool(product))
      end

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
      measurements = {}
    
      raw_attributes =
        safe_hash(product.full_attributes)
          .merge(safe_hash(product.dimensions))
          .merge(safe_hash(product.dimensions_ru))
    
      attributes = flatten_hash(raw_attributes)
    
      MEASUREMENT_KEYS.each do |type, keys|
        found = false
    
        keys.each do |key|
          attributes.each do |attr_key, attr_value|
            next unless normalize_text(attr_key).include?(normalize_text(key))
    
            number = extract_number(attr_value)
            next if number.nil?
    
            measurements[type] = number
            found = true
            break
          end
    
          break if found
        end
      end
    
      measurements
    end

    def parse_measurement_bucket(value_id)
      match = value_id.to_s.match(/\A(WIDTH|HEIGHT|DEPTH|LENGTH|DIAMETER|VOLUME)_(\d+)_([0-9]+)\z/)
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

      raw_attributes = {}
      raw_attributes.merge!(safe_hash(product.full_attributes))
      raw_attributes.merge!(safe_hash(product.dimensions)) if product.respond_to?(:dimensions)
      raw_attributes.merge!(safe_hash(product.dimensions_ru)) if product.respond_to?(:dimensions_ru)

      attributes = flatten_hash(raw_attributes)
      normalized_keys = Array(keys).map { |key| normalize_text(key) }.reject(&:blank?)
      values = []

      attributes.each do |attr_key, attr_value|
        normalized_attr_key = normalize_text(attr_key)
        next if normalized_attr_key.blank?
        next unless normalized_keys.any? { |key| normalized_attr_key.include?(key) || key.include?(normalized_attr_key) }

        values.concat(normalize_value(attr_value))
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
      pool = [
        product.name,
        product.name_ru,
        product.small_desc_name,
        product.collection,
        product.short_description,
        product.short_description_ru,
        product.material_info,
        product.material_info_ru,
        product.good_info,
        product.good_info_ru,
        product.dimensions,
        product.dimensions_ru,
        product.package_dimensions
      ].compact.map(&:to_s)

      (product.full_attributes || {}).each do |k, v|
        pool << k.to_s
        normalize_value(v).each { |vv| pool << vv.to_s }
      end

      material_text_pool(product).each { |v| pool << v.to_s }
      normalize_value(product.features).each { |v| pool << v.to_s }
      normalize_value(product.features_ru).each { |v| pool << v.to_s }

      pool
    end

    def material_text_pool(product)
      [
        product.materials,
        product.materials_ru,
        product.material_info,
        product.material_info_ru
      ].flat_map { |value| normalize_value(value) }
    end

    def dimension_text_pool(product)
      [
        product.dimensions,
        product.dimensions_ru,
        product.package_dimensions
      ].flat_map { |value| normalize_value(value) }
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
      val_norms = values.map { |v| normalize_text(v) }
      
      # 1. Прямое совпадение
      return true if val_norms.any? { |v| v.include?(target_norm) }
      
      # 2. Совпадение через универсальный словарь переводов
      # Ищем перевод: ключ словаря должен быть частью target_norm (или наоборот)
      translation_entry = VALUE_TRANSLATIONS.find do |k, _| 
        k_norm = normalize_text(k)
        target_norm.include?(k_norm) || k_norm.include?(target_norm)
      end
      
      if translation_entry
        translations = translation_entry.last
        trans_norms = translations.map { |t| normalize_text(t) }
        return true if val_norms.any? do |v|
          trans_norms.any? { |t| v.include?(t) }
        end
      end

      false
    end

    def normalize_text(value)
      return "" if value.blank?
      
      text = value.to_s.downcase
      
      # Убираем диакритику, которая часто встречается в PL/LT/SV названиях IKEA
      text = text.tr('ąćęłńóśźżäöüå', 'acelnoszzaoua')
      # Убираем русскую "ё"
      text = text.tr('ё', 'е')
      
      text.tr("\u00A0", " ").squeeze(" ").strip
    end

    def flatten_hash(hash, result = {})
      hash.each do |k, v|
        if v.is_a?(Hash)
          flatten_hash(v, result)
        else
          result[k] = v
        end
      end
    
      result
    end
    
    def safe_hash(value)
      return {} if value.blank?
      return value if value.is_a?(Hash)
    
      if value.is_a?(String)
        parsed = JSON.parse(value) rescue nil
        return parsed if parsed.is_a?(Hash)
      end
    
      {}
    end

    def extract_series_names_from_product(product, available_series_names)
      texts = [
        product.name_ru,
        product.name,
        product.small_desc_name,
        (product.respond_to?(:collection) ? product.collection : nil)
      ].compact.map { |text| normalize_series_text(text) }.uniq
    
      return [] if texts.empty?
      return [] if available_series_names.blank?
    
      available_series_names.select do |series_name|
        texts.any? { |text| series_name_in_text?(series_name, text) }
      end
    end
    
    def series_name_in_text?(series_name, text)
      return false if series_name.blank? || text.blank?
    
      normalized_series = series_name.to_s.upcase.strip
      return false if normalized_series.blank?
    
      text.match?(series_name_regex(normalized_series))
    end
    
    def series_name_regex(series_name)
      /(^|[^[:alnum:]])#{Regexp.escape(series_name)}([^[:alnum:]]|$)/i
    end
    
    def normalize_series_text(value)
      normalize_text(value).upcase
    end

    def normalize_series_name(name)
      return nil if name.blank?
    
      text = name.to_s.dup.strip
      text = text.tr("ё", "е")
    
      text = text.gsub(/\A\s*[СC]\s*ЕРИЯ\s+ДЛЯ\s+.*?\s+/i, "")
      text = text.gsub(/\A\s*[СC]\s*ЕРИЯ\s+/i, "")
      text = text.gsub(/\A\s*СТЕЛЛАЖИ\s+/i, "")
      text = text.gsub(/\A\s*КНИЖНЫЕ ШКАФЫ\s+/i, "")
      text = text.gsub(/\A\s*ДВЕРИ\s+/i, "")
      text = text.gsub(/\A\s*ФУРНИТУРА И ВНУТРЕННИЕ ОРГАНАЙЗЕРЫ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ СТУЛЬЯ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ СТОЛЫ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ ГАРНИТУРЫ\s+/i, "")
      text = text.gsub(/\A\s*АКСЕССУАРЫ\s+/i, "")
      text = text.gsub(/\A\s*ПЕРФОРИРОВАННЫЕ ДОСКИ\s+/i, "")
      text = text.gsub(/\A\s*ВСТАВКИ И АКСЕССУАРЫ ДЛЯ\s+/i, "")
    
      text = normalize_series_text(text)
      text.presence
    end
  end
end
