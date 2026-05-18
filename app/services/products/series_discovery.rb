# frozen_string_literal: true

module Products
  # Извлекает сырые подписи серий из товара (collection, атрибуты Seria/…, заголовки).
  module SeriesDiscovery
    ATTRIBUTE_KEYS = FilterValuesIndexer::PARAMETER_KEYS.fetch("f-series").freeze
    NAME_TOKEN_PATTERN = /\b([A-ZÅÄÖÆ][A-ZÅÄÖÆ0-9\-]{3,})\b/
    TOKEN_BLACKLIST = %w[
      LED RGB WIFI USB PLN BYN IKEA VOL E27 GU10 RGBW SMART WHITE BLACK SILVER ANTHRACITE
      OPAL GLASS STEEL ALUMINIUM PLASTIC BATTERY SENSOR DIMMABLE DIMMAB
    ].freeze

    module_function

    def raw_labels_from_product(product)
      labels = []
      labels << product.collection.to_s.strip if product.collection.present?
      labels.concat(series_from_full_attributes(product))
      labels.concat(tokens_from_titles(product))

      labels.map(&:strip).reject(&:blank?).uniq
    end

    def series_from_full_attributes(product)
      raw = product.full_attributes
      return [] if raw.blank?

      attrs =
        if raw.is_a?(Hash)
          raw
        else
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return []
          end
        end
      return [] unless attrs.is_a?(Hash)

      normalized_keys = ATTRIBUTE_KEYS.map { |k| normalize_attr_key(k) }.reject(&:blank?)
      values = []

      each_attribute(attrs) do |attr_key, attr_value|
        next unless normalized_keys.any? { |key| attr_key.include?(key) || key.include?(attr_key) }

        values.concat(normalize_attr_values(attr_value))
      end

      values
    end

    def tokens_from_titles(product)
      pool = [product.name_ru, product.name, product.small_desc_name].compact.join(" ")
      return [] if pool.blank?

      pool.scan(NAME_TOKEN_PATTERN).filter_map do |token|
        token = token.to_s.strip
        next if token.blank?
        next if TOKEN_BLACKLIST.include?(token.upcase)

        token
      end.uniq
    end

    def each_attribute(obj, &block)
      case obj
      when Hash
        obj.each do |key, value|
          if value.is_a?(Hash)
            each_attribute(value, &block)
          else
            yield normalize_attr_key(key), value
          end
        end
      when Array
        obj.each { |item| each_attribute(item, &block) if item.is_a?(Hash) }
      end
    end

    def normalize_attr_key(key)
      text = key.to_s.downcase
      text = text.tr("ąćęłńóśźżäöüå", "acelnoszzaoua")
      text.tr("ё", "е").tr("\u00A0", " ").squeeze(" ").strip
    end

    def normalize_attr_values(value)
      case value
      when Array
        value.flat_map { |v| normalize_attr_values(v) }
      when Hash
        value.values.flat_map { |v| normalize_attr_values(v) }
      when nil
        []
      else
        [value.to_s.strip]
      end.reject(&:blank?)
    end
  end
end
