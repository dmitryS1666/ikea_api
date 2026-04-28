module Products
  class SearchService
    EXCLUDED_FILTER_PARAMETERS = %w[f-type].freeze

    def initialize(category, params = {})
      @category = category
      @params = params || {}
      @scope = initial_scope
    end

    def call
      @scope = @scope.merge(Product.with_available_stock)
      filter_by_display_price
      filter_by_attributes
      sort_results

      @scope
    end

    private

    def initial_scope
      if @category&.ikea_id.present?
        Product.catalog_category_scope(@category.ikea_id)
      else
        Product.active
      end
    rescue NoMethodError
      @category&.products&.active || Product.active
    rescue StandardError
      Product.active
    end

    # На витрине и в Category#display_filters_for_api цена отдается в BYN
    # через PriceCalculationService.product_price_byn(...).
    # Поэтому входные min_price/max_price тоже сравниваем с расчетной BYN-ценой,
    # а не с сырой products.price в PLN.
    def filter_by_display_price
      min_price = number_from_param(@params[:min_price])
      max_price = number_from_param(@params[:max_price])
      return if min_price.nil? && max_price.nil?

      matching_ids = ids_matching_display_price(min_price, max_price)
      @scope = matching_ids.empty? ? @scope.none : @scope.where(id: matching_ids)
    end

    def ids_matching_display_price(min_price, max_price)
      pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      buffer = CalculatorSetting.get('exchange_rate_buffer') || PriceCalculationService.exchange_rate_buffer

      @scope
        .where.not(price: nil)
        .pluck(:id, :price, :weight, :delivery_cost)
        .filter_map do |id, price, weight, delivery_cost|
          price_byn = PriceCalculationService.product_price_byn(
            price.to_f,
            weight_kg: weight.to_f,
            delivery_pln: delivery_cost.to_f,
            pln_rate: pln_rate,
            buffer: buffer
          )

          next if min_price && price_byn < min_price
          next if max_price && price_byn > max_price

          id
        end
    end

    def number_from_param(value)
      text = value.to_s.tr(',', '.').gsub(/[^\d.]/, '')
      return nil if text.blank?

      text.to_f
    end

    def filter_by_attributes
      filters = @params[:filters]
      return unless filters.present? && (filters.is_a?(Hash) || filters.is_a?(ActionController::Parameters))
      return unless @category&.ikea_id

      filters.each do |filter_param, values|
        filter_param = filter_param.to_s
        next if filter_param.blank?
        next if filter_param == 'f-price-buckets'
        next if filter_param == 'f-availability'
        next if EXCLUDED_FILTER_PARAMETERS.include?(filter_param)

        value_ids = Array(values).map(&:to_s).reject(&:blank?)
        next if value_ids.empty?

        subquery = ProductFilterValue
                     .where(category_id: @category.ikea_id, parameter: filter_param, value_id: value_ids)
                     .select(:product_id)

        @scope = @scope.where(id: subquery)
      end
    end

    def sort_results
      sort_option = @params[:sort] || @category.try(:default_sort) || 'popular'

      case sort_option.to_s
      when 'cheapest'
        @scope = sort_by_display_price(direction: :asc)
      when 'expensive'
        @scope = sort_by_display_price(direction: :desc)
      when 'newest'
        @scope = @scope.order('products.created_at DESC')
      when 'popular'
        @scope = @scope.order(Arel.sql('products.popularity_score DESC, products.rating_weighted DESC, products.views_count DESC'))
      else
        @scope = @scope.order('products.id DESC')
      end
    end

    def sort_by_display_price(direction:)
      pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      buffer = CalculatorSetting.get('exchange_rate_buffer') || PriceCalculationService.exchange_rate_buffer

      priced_rows = @scope.where.not(price: nil).pluck(:id, :price, :weight, :delivery_cost)
      return fallback_price_sort(direction) if priced_rows.empty?

      sorted_ids =
        priced_rows
          .map do |id, price, weight, delivery_cost|
            price_byn = PriceCalculationService.product_price_byn(
              price.to_f,
              weight_kg: weight.to_f,
              delivery_pln: delivery_cost.to_f,
              pln_rate: pln_rate,
              buffer: buffer
            )

            [id, price_byn]
          end
          .sort_by do |id, price_byn|
            direction == :asc ? [price_byn, id] : [-price_byn, -id]
          end
          .map(&:first)

      return fallback_price_sort(direction) if sorted_ids.empty?

      case_sql = +"CASE products.id "
      sorted_ids.each_with_index { |id, idx| case_sql << "WHEN #{id.to_i} THEN #{idx} " }
      case_sql << "ELSE #{sorted_ids.length} END"

      id_order = direction == :asc ? 'ASC' : 'DESC'
      @scope.reorder(Arel.sql(case_sql)).order(Arel.sql("products.id #{id_order}"))
    end

    def fallback_price_sort(direction)
      direction_sql = direction == :asc ? 'ASC' : 'DESC'
      id_sql = direction == :asc ? 'ASC' : 'DESC'
      @scope.reorder(Arel.sql("products.price #{direction_sql} NULLS LAST, products.id #{id_sql}"))
    end
  end
end
