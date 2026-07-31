# frozen_string_literal: true

require "httparty"
require "set"

module Categories
  # Копирует точную классификацию SKU из фасетного поиска IKEA.
  #
  # Для каждого parameter/value_id выполняется тот же запрос, который делает
  # витрина IKEA, и результат сохраняется в product_filter_values. Никаких
  # совпадений по названию, описанию или словарям здесь нет.
  class IkeaFacetMembershipSyncService
    SEARCH_URL = Categories::LtAvailableFiltersRefreshService::SEARCH_URL
    PAGE_SIZE = 1_000

    Result = Struct.new(
      :filters_count,
      :values_count,
      :memberships_count,
      :unmatched_skus,
      keyword_init: true
    )

    def initialize(category)
      @category = category
    end

    def call
      filters = upstream_filters
      raise "IKEA returned no working facets for category #{@category.ikea_id}" if filters.empty?

      rows = []
      unmatched = Set.new
      values_count = 0

      filters.each do |filter|
        parameter = filter["parameter"].to_s

        Array(filter["values"]).each do |value|
          value = value.deep_stringify_keys
          next if value["id"].blank?
          next if value.key?("count") && value["count"].to_i <= 0

          values_count += 1
          skus = fetch_skus(parameter, value["id"])
          if value["count"].to_i.positive? && skus.empty?
            raise "IKEA facet #{parameter}=#{value['id']} has count=#{value['count']} but returned no SKU"
          end

          skus.each do |sku|
            product = Products::ListingSkuResolver.find_product(sku)
            unless product
              unmatched << sku
              next
            end

            rows << membership_row(product.id, parameter, value["id"])
          end
        end
      end

      rows.uniq! { |row| [row[:product_id], row[:category_id], row[:parameter], row[:value_id]] }

      ProductFilterValue.transaction do
        ProductFilterValue
          .where(category_id: @category.ikea_id)
          .where.not(parameter: Categories::FilterPolicy::LOCAL_PARAMETERS)
          .delete_all
        ProductFilterValue.insert_all(rows, unique_by: :index_product_filter_values_unique) if rows.any?
      end

      Categories::ShowCache.bust!(@category.ikea_id)

      Result.new(
        filters_count: filters.size,
        values_count: values_count,
        memberships_count: rows.size,
        unmatched_skus: unmatched.to_a.sort
      )
    end

    private

    def upstream_filters
      Array(@category.available_filters).filter_map do |raw|
        next unless raw.is_a?(Hash)

        filter = raw.deep_stringify_keys
        parameter = filter["parameter"].to_s
        next unless Categories::FilterPolicy.upstream?(parameter)

        values = Array(filter["values"]).select do |value|
          value.is_a?(Hash) &&
            value["id"].present? &&
            (!value.key?("count") || value["count"].to_i.positive?)
        end
        next if values.empty?

        filter.merge("values" => values)
      end
    end

    def fetch_skus(parameter, value_id)
      offset = 0
      skus = []

      loop do
        response = search(parameter, value_id, offset)
        items = Array(response.dig("results", 0, "items"))
        products = items.filter_map { |item| item.is_a?(Hash) ? item["product"] : nil }

        products.each do |product|
          [
            product["id"],
            product["itemNoGlobal"],
            product["itemNo"]
          ].compact.each do |sku|
            skus << sku.to_s if sku.present?
          end
        end

        break if items.size < PAGE_SIZE || products.empty?

        offset += PAGE_SIZE
      end

      skus.uniq
    end

    def search(parameter, value_id, offset)
      response = ProxyRotator.with_proxy_retry do |proxy_options|
        HTTParty.post(
          SEARCH_URL,
          body: request_body(parameter, value_id, offset).to_json,
          headers: request_headers,
          timeout: 45,
          **(proxy_options || {})
        )
      end

      unless response.respond_to?(:success?) && response.success?
        raise "IKEA facet request failed category=#{@category.ikea_id} " \
              "#{parameter}=#{value_id}: HTTP #{response&.code}"
      end

      response.parsed_response.deep_stringify_keys
    end

    def request_body(parameter, value_id, offset)
      {
        searchParameters: { input: @category.ikea_id.to_s, type: "CATEGORY" },
        isUserLoggedIn: false,
        components: [{
          component: "PRIMARY_AREA",
          columns: 4,
          types: {
            main: "PRODUCT",
            breakouts: ["PLANNER", "LOGIN_REMINDER", "MATTRESS_WARRANTY"]
          },
          filterConfig: {
            parameter => [value_id.to_s],
            "max-num-filters" => 50
          },
          sort: "RELEVANCE",
          allVariants: true,
          allowGprDeduplication: false,
          window: { offset: offset, size: PAGE_SIZE }
        }]
      }
    end

    def request_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Accept-Language" => "ru-RU,ru;q=0.9",
        "User-Agent" => ENV.fetch(
          "USER_AGENT",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        )
      }
    end

    def membership_row(product_id, parameter, value_id)
      now = Time.current
      {
        product_id: product_id,
        category_id: @category.ikea_id,
        parameter: parameter.to_s,
        value_id: value_id.to_s,
        created_at: now,
        updated_at: now
      }
    end
  end
end
