module Products
  class SearchService
    EXCLUDED_FILTER_PARAMETERS = %w[f-type].freeze
    SKIPPED_FILTER_PARAMETERS = %w[f-availability f-price-buckets].freeze

    def initialize(category, params = {}, base_scope: nil, default_sort: nil)
      @category = category
      @params = params || {}
      @base_scope = base_scope
      @default_sort = default_sort
      @scope = initial_scope
    end

    def call
      @scope = @scope.merge(Product.with_available_stock) unless @base_scope
      filter_by_display_price
      filter_by_attributes
      sort_results

      @scope
    end

    private

    def initial_scope
      if @base_scope
        @base_scope
      elsif @category&.ikea_id.present?
        ikea_ids = @category.self_and_descendant_ikea_ids
        Product.in_categories_ikea_ids(ikea_ids).active.with_available_stock
      else
        Product.active
      end
    rescue NoMethodError
      @base_scope || @category&.products&.active || Product.active
    rescue StandardError
      @base_scope || Product.active
    end

    # На витрине и в Category#display_filters_for_api цена отдается в BYN
    # через PriceCalculationService.product_storefront_price_byn(..., weight_kg: packaging_weight_kg).
    # Поэтому min_price/max_price сравниваем с той же формулой, а не с products.price в PLN.
    def filter_by_display_price
      min_price, max_price = effective_price_bounds
      return if min_price.nil? && max_price.nil?

      matching_ids = ids_matching_display_price(min_price, max_price)
      @scope = matching_ids.empty? ? @scope.none : @scope.where(id: matching_ids)
    end

    def effective_price_bounds
      min_price = number_from_param(@params[:min_price])
      max_price = number_from_param(@params[:max_price])

      price_filter = @params[:filters]
      if price_filter.present? && (price_filter.is_a?(Hash) || price_filter.is_a?(ActionController::Parameters))
        bucket_param = price_filter["f-price-buckets"] || price_filter[:f_price_buckets]
        if bucket_param.is_a?(Hash) || bucket_param.is_a?(ActionController::Parameters)
          min_price = number_from_param(bucket_param[:min] || bucket_param["min"]) if min_price.nil?
          max_price = number_from_param(bucket_param[:max] || bucket_param["max"]) if max_price.nil?
        end
      end

      [min_price, max_price]
    end

    def ids_matching_display_price(min_price, max_price)
      pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
      buffer = CalculatorSetting.get("exchange_rate_buffer") || PriceCalculationService.exchange_rate_buffer
      matching_ids = []

      @scope.where.not(price: nil).find_in_batches(batch_size: 200) do |batch|
        batch.each do |product|
          price_byn = display_price_byn_for_product(product, pln_rate: pln_rate, buffer: buffer)
          next if !min_price.nil? && price_byn < min_price.to_f
          next if !max_price.nil? && price_byn > max_price.to_f

          matching_ids << product.id
        end
      end

      matching_ids
    end

    def display_price_byn_for_product(product, pln_rate: nil, buffer: nil)
      pln_rate ||= ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
      buffer ||= CalculatorSetting.get("exchange_rate_buffer") || PriceCalculationService.exchange_rate_buffer

      PriceCalculationService.product_storefront_price_byn(
        product.price.to_f,
        weight_kg: product.packaging_weight_kg.to_f,
        delivery_pln: product.delivery_cost.to_f,
        pln_rate: pln_rate,
        buffer: buffer
      )
    end

    def number_from_param(value)
      text = value.to_s.tr(',', '.').gsub(/[^\d.]/, '')
      return nil if text.blank?

      text.to_f
    end

    def filter_by_attributes
      filters = @params[:filters]
      return unless filters.present? && (filters.is_a?(Hash) || filters.is_a?(ActionController::Parameters))

      filters.each do |filter_param, values|
        filter_param = filter_param.to_s
        next if filter_param.blank?
        next if SKIPPED_FILTER_PARAMETERS.include?(filter_param)
        next if EXCLUDED_FILTER_PARAMETERS.include?(filter_param)

        if filter_param == "f-price-buckets" && (values.is_a?(Hash) || values.is_a?(ActionController::Parameters))
          next
        end

        value_ids = Array(values).map(&:to_s).reject(&:blank?)
        value_ids -= ["PRICE_RANGE"]
        next if value_ids.empty?

        subquery = filter_values_subquery(filter_param, value_ids)
        @scope = @scope.where(id: subquery)
      end
    end

    def filter_values_subquery(filter_param, value_ids)
      if @category&.ikea_id.present?
        category_ikea_ids = @category.self_and_descendant_ikea_ids
        ProductFilterValue
          .where(category_id: category_ikea_ids, parameter: filter_param, value_id: value_ids)
      else
        ProductFilterValue
          .where(product_id: @scope.select(:id), parameter: filter_param, value_id: value_ids)
      end.select(:product_id)
    end

    def sort_results
      sort_option = @params[:sort].presence || @default_sort || @category.try(:default_sort) || "popular"

      case sort_option.to_s
      when "relevance"
        preserve_scope_order(@scope)
      when "cheapest"
        @scope = sort_by_display_price(direction: :asc)
      when "expensive"
        @scope = sort_by_display_price(direction: :desc)
      when "newest"
        @scope = @scope.order("products.created_at DESC")
      when "popular"
        @scope = @scope.order(Arel.sql("products.popularity_score DESC, products.rating_weighted DESC, products.views_count DESC"))
      else
        @scope = @scope.order("products.id DESC")
      end
    end

    def preserve_scope_order(scope)
      return scope if scope.order_values.present?

      ordered_ids = scope.pluck(:id)
      return scope.none if ordered_ids.empty?

      scope.in_order_of(:id, ordered_ids)
    end

    def sort_by_display_price(direction:)
      pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
      buffer = CalculatorSetting.get("exchange_rate_buffer") || PriceCalculationService.exchange_rate_buffer
      priced = []

      @scope.where.not(price: nil).find_in_batches(batch_size: 200) do |batch|
        batch.each do |product|
          priced << [
            product.id,
            display_price_byn_for_product(product, pln_rate: pln_rate, buffer: buffer)
          ]
        end
      end

      return @scope.none if priced.empty?

      sorted = priced.sort_by { |(_id, price)| direction == :asc ? price : -price }
      sorted_ids = sorted.map(&:first)
      case_sql = sorted_ids.each_with_index.map { |id, idx| "WHEN #{id.to_i} THEN #{idx}" }.join(" ")

      @scope.where(id: sorted_ids).reorder(Arel.sql("CASE products.id #{case_sql} END"))
    end
  end
end
