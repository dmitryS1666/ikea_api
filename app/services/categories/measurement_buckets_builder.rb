# frozen_string_literal: true

module Categories
  class MeasurementBucketsBuilder
    MEASUREMENT_CONFIG = {
      width:    { prefix: "WIDTH",    label: "Ширина",  step: 50 },
      height:   { prefix: "HEIGHT",   label: "Высота",  step: 10 },
      depth:    { prefix: "DEPTH",    label: "Глубина", step: 10 },
      length:   { prefix: "LENGTH",   label: "Длина",   step: 10 },
      diameter: { prefix: "DIAMETER", label: "Диаметр", step: 10 },
      volume:   { prefix: "VOLUME",   label: "Объем",   step: 10 }
    }.freeze

    HUGE_MAX = 9_223_372_036_854_775_807

    class << self
      def call(category)
        new(category).call
      end
    end

    def initialize(category)
      @category = category
      @indexer = Products::FilterValuesIndexer.new(category)
    end

    def call
      filters = normalize_filters(category.available_filters)
      measurement_filter = filters.find { |f| f["parameter"].to_s == "f-measurement-buckets" }
      return false unless measurement_filter

      values_by_type = collect_measurements
      new_values = build_values(values_by_type)

      filters = filters.reject { |f| f["parameter"].to_s == "f-measurement-buckets" }

      if new_values.any?
        filters << measurement_filter.merge("values" => new_values)
      end

      category.update_columns(available_filters: filters)
      true
    end

    private

    attr_reader :category, :indexer

    def collect_measurements
      result = Hash.new { |h, k| h[k] = [] }

      Product.catalog_category_scope(category.ikea_id).find_each do |product|
        measurements = indexer.send(:extract_measurements, product)

        measurements.each do |type, value|
          next unless MEASUREMENT_CONFIG.key?(type)
          next if value.blank?
          next if value.to_f <= 0

          result[type] << value.to_f
        end
      end

      result.transform_values { |values| values.compact.uniq.sort }
    end

    def build_values(values_by_type)
      values_by_type.flat_map do |type, values|
        next [] if values.blank?

        config = MEASUREMENT_CONFIG.fetch(type)
        buckets = build_buckets_for_values(values, step: config[:step])

        buckets.map do |bucket|
          {
            "id" => "#{config[:prefix]}_#{bucket[:min]}_#{bucket[:max]}",
            "name" => bucket_name(config[:label], bucket[:min], bucket[:max])
          }
        end
      end
    end

    def build_buckets_for_values(values, step:)
      min_value = values.min.floor
      max_value = values.max.ceil

      bucket_start = (min_value / step) * step
      bucket_end_limit = ((max_value / step) * step) + step

      buckets = []
      current = bucket_start

      while current < bucket_end_limit
        bucket_min = current
        bucket_max_exclusive = current + step

        has_value = values.any? do |value|
          value >= bucket_min && value < bucket_max_exclusive
        end

        if has_value
          buckets << {
            min: bucket_min,
            max: bucket_max_exclusive
          }
        end

        current += step
      end

      buckets
    end

    def bucket_name(label, min, max_exclusive)
      max_inclusive = max_exclusive - 1

      if min == max_inclusive
        "#{label}: #{min} см"
      else
        "#{label}: #{min} - #{max_inclusive} см"
      end
    end

    def normalize_filters(filters)
      Array(filters).compact.map do |filter|
        filter.is_a?(Hash) ? filter.deep_stringify_keys : nil
      end.compact
    end
  end
end
