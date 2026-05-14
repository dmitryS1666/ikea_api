# frozen_string_literal: true

module Products
  class WeightExtractor
    FILLER_WEIGHT_KEYS = [
      "вес наполнителя",
      "вес наполнения",
      "масса наполнителя",
      "масса наполнения"
    ].freeze

    class << self
      def extract_kg_from_text(text)
        return nil if text.blank?
      
        str = text.to_s.downcase.tr(",", ".").gsub(/\s+/, " ").strip
      
        # 415 гр / 415 г / 415g / 1 кг / 1.2 кг
        match = str.match(/(\d+(?:\.\d+)?)\s*(кг|kg|гр|г|g)\b/)
        return nil unless match
      
        num = match[1].to_f
        unit = match[2]
      
        return nil unless num.positive?
      
        if ["кг", "kg"].include?(unit)
          num.round(3)
        else
          (num / 1000.0).round(3)
        end
      end

      # Возвращает вес в килограммах.
      #
      # Приоритет:
      # 1. size.packaging.details[].weight × count
      # 2. size.packages[].measurements[name == "Вес"]
      # 3. size["Общий вес"]
      #
      # Намеренно НЕ используем "Вес наполнителя".
      def extract_kg(source)
        data = deep_stringify(source)
        size = extract_size_block(data)

        return nil unless size.is_a?(Hash)

        from_packaging_details(size) ||
          from_packages(size) ||
          from_total_weight(size)
      end

      # Только упаковка: `packaging.details` и `packages` (без «Общий вес» и без колонки `products.weight`).
      def extract_packaging_kg(source)
        data = deep_stringify(source)
        size = extract_size_block(data)
        return nil unless size.is_a?(Hash)

        from_packaging_details(size) || from_packages(size)
      end

      def packaging_weight_kg_for_product(product)
        return nil unless product.is_a?(Product)

        payload = ProductSerializer.customer_full_attributes_payload(product)
        extract_packaging_kg(payload)
      rescue StandardError
        nil
      end

      def parse_weight_to_kg(value, allow_unitless: false)
        return nil if value.blank?

        if value.is_a?(Numeric)
          return nil unless allow_unitless

          kg = value.to_f
          return nil unless kg.positive?

          return kg.round(3)
        end

        str = value.to_s.downcase.tr(",", ".").gsub(/\s+/, " ").strip
        return nil if str.blank?

        num = str[/\d+(?:\.\d+)?/]&.to_f
        return nil unless num&.positive?

        if str.include?("кг") || str.include?("kg")
          return num.round(3)
        end

        if str.include?("гр") || str.match?(/(^|[\s\d])г\.?($|\s)/) || str.include?(" g")
          return (num / 1000.0).round(3)
        end

        return nil unless allow_unitless

        # Без единиц измерения принимаем только реалистичный вес в кг.
        # Это защищает от кейса "330" => 330 кг.
        return nil if num > 100

        num.round(3)
      end

      private

      def extract_size_block(data)
        return data["size"] if data["size"].is_a?(Hash)
        return data.dig("full_attributes_ru", "size") if data.dig("full_attributes_ru", "size").is_a?(Hash)
        return data.dig("attributes", "full_attributes_ru", "size") if data.dig("attributes", "full_attributes_ru", "size").is_a?(Hash)

        data
      end

      def from_packaging_details(size)
        details = size.dig("packaging", "details")
        return nil unless details.is_a?(Array) && details.any?

        total = details.sum do |row|
          next 0 unless row.is_a?(Hash)

          weight = parse_weight_to_kg(row["weight"], allow_unitless: true)
          count = parse_count(row["count"])

          next 0 unless weight&.positive?

          weight * count
        end

        total.positive? ? total.round(3) : nil
      end

      def from_packages(size)
        packages = size["packages"]
        return nil unless packages.is_a?(Array) && packages.any?

        total = packages.sum do |package|
          next 0 unless package.is_a?(Hash)

          measurements = package["measurements"]
          next 0 unless measurements.is_a?(Array)

          weight_row = measurements.find do |measurement|
            measurement.is_a?(Hash) && normalize_key(measurement["name"]) == "вес"
          end

          next 0 unless weight_row

          weight = parse_weight_to_kg(weight_row["measure"], allow_unitless: false)
          count = package_count_from_measurements(measurements)

          next 0 unless weight&.positive?

          weight * count
        end

        total.positive? ? total.round(3) : nil
      end

      def from_total_weight(size)
        key, value = size.find do |raw_key, _raw_value|
          normalized = normalize_key(raw_key)
          normalized == "общий вес"
        end

        return nil if key.blank? || value.blank?

        parse_weight_to_kg(value, allow_unitless: false)
      end

      def package_count_from_measurements(measurements)
        count_row = measurements.find do |measurement|
          measurement.is_a?(Hash) &&
            ["упаковка(-и)", "упаковки", "количество упаковок"].include?(normalize_key(measurement["name"]))
        end

        parse_count(count_row&.dig("measure"))
      end

      def parse_count(value)
        count = value.to_s[/\d+/].to_i
        count.positive? ? count : 1
      end

      def normalize_key(value)
        value.to_s.downcase.gsub(":", "").gsub(/\s+/, " ").strip
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, val), result|
            result[key.to_s] = deep_stringify(val)
          end
        when Array
          value.map { |item| deep_stringify(item) }
        else
          value
        end
      end
    end
  end
end