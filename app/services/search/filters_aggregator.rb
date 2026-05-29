# frozen_string_literal: true

module Search
  # Агрегирует available_filters для /api/v1/search/suggest по найденным товарам и категориям.
  class FiltersAggregator
    SKIP_PARAMETERS = %w[f-availability f-subcategories f-price-buckets].freeze

    def initialize(products_scope, categories)
      @products_scope = products_scope
      @categories = Array(categories).compact
    end

    def call
      return [] if @products_scope.blank? || @categories.blank?

      counts = ProductFilterValue.where(product_id: @products_scope.select(:id))
                                 .group(:parameter, :value_id)
                                 .count

      param_to_values = {}
      counts.each do |(param, value_id), count|
        param_to_values[param] ||= {}
        param_to_values[param][value_id.to_s] = count
      end

      aggregated = {}

      @categories.each do |category|
        filters_to_use =
          if category.respond_to?(:display_filters_for_api)
            category.display_filters_for_api
          else
            category.available_filters || []
          end
        next if filters_to_use.blank?

        filters_to_use.each do |filter|
          param = filter["parameter"].to_s
          next if param.blank?
          next if SKIP_PARAMETERS.include?(param)
          next unless param_to_values.key?(param)

          matching_values = Array(filter["values"]).filter_map do |value|
            value_id = value["id"].to_s
            count = param_to_values[param][value_id]
            next if count.nil? || count.zero?

            value_entry = value.except("count").merge("count" => count)
            value_entry["translated_name"] ||= value_entry["name"]
            value_entry
          end

          next if matching_values.empty?

          if aggregated[param]
            merge_filter_values!(aggregated[param], matching_values)
          else
            aggregated[param] = build_filter_entry(filter, matching_values)
          end
        end
      end

      aggregated.values
    end

    private

    def build_filter_entry(filter, matching_values)
      label = filter["translated_name"].presence || filter["name"].to_s

      {
        "parameter" => filter["parameter"],
        "name" => filter["name"],
        "translated_name" => label,
        "values" => matching_values
      }
    end

    def merge_filter_values!(existing, matching_values)
      known_ids = existing["values"].map { |value| value["id"].to_s }.to_set

      matching_values.each do |value|
        next if known_ids.include?(value["id"].to_s)

        existing["values"] << value
        known_ids << value["id"].to_s
      end
    end
  end
end
