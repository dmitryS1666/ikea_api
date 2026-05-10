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
        ikea_ids = @category.self_and_descendant_ikea_ids
        Product.in_categories_ikea_ids(ikea_ids).active.with_available_stock
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
      scope = @scope.where.not(price: nil)
      price_sql = display_price_byn_sql
      scope = scope.where("#{price_sql} >= ?", min_price.to_f) if min_price
      scope = scope.where("#{price_sql} <= ?", max_price.to_f) if max_price
      scope.pluck(:id)
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

      category_ikea_ids = @category.self_and_descendant_ikea_ids

      filters.each do |filter_param, values|
        filter_param = filter_param.to_s
        next if filter_param.blank?
        next if filter_param == 'f-price-buckets'
        next if filter_param == 'f-availability'
        next if EXCLUDED_FILTER_PARAMETERS.include?(filter_param)

        value_ids = Array(values).map(&:to_s).reject(&:blank?)
        next if value_ids.empty?

        subquery = ProductFilterValue
                     .where(category_id: category_ikea_ids, parameter: filter_param, value_id: value_ids)
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
      direction_sql = direction == :asc ? 'ASC' : 'DESC'
      id_sql = direction == :asc ? 'ASC' : 'DESC'
      price_sql = display_price_byn_sql
      @scope.where.not(price: nil).reorder(Arel.sql("#{price_sql} #{direction_sql}, products.id #{id_sql}"))
    end

    def fallback_price_sort(direction)
      direction_sql = direction == :asc ? 'ASC' : 'DESC'
      id_sql = direction == :asc ? 'ASC' : 'DESC'
      @scope.reorder(Arel.sql("products.price #{direction_sql} NULLS LAST, products.id #{id_sql}"))
    end

    def display_price_byn_sql
      pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      buffer = CalculatorSetting.get('exchange_rate_buffer') || PriceCalculationService.exchange_rate_buffer
      cheap_threshold = PriceCalculationService.cheap_threshold_pln
      delivery_case_sql = belarus_delivery_per_kg_sql

      effective_pln_rate = pln_rate.to_f
      effective_buffer = buffer.to_f

      # Реплицируем формулу PriceCalculationService.product_price_byn(...) в SQL:
      # 1) считаем total_pln по cheap/k режиму;
      # 2) конвертируем в BYN через pln_rate * buffer.
      <<~SQL.squish
        (
          CASE
            WHEN products.price <= #{cheap_threshold.to_f}
              THEN (
                (
                  products.price
                  + COALESCE(products.delivery_cost, 0)
                  + (
                    COALESCE(products.weight, 0) *
                    #{delivery_case_sql}
                  )
                ) * 1.3
              )
            ELSE (
              (
                products.price * (
                  1 + GREATEST((87.0 / NULLIF(products.price, 0)) - 0.187, 0.10)
                )
              )
              + COALESCE(products.delivery_cost, 0)
              + (
                COALESCE(products.weight, 0) *
                #{delivery_case_sql}
              )
            )
          END
        ) * #{effective_pln_rate} * #{effective_buffer}
      SQL
    end

    def belarus_delivery_per_kg_sql
      clauses = BelarusDeliveryService.delivery_rates.map do |(min_weight, max_weight), rate|
        if max_weight.finite?
          "WHEN COALESCE(products.weight, 0) > #{min_weight.to_f} AND COALESCE(products.weight, 0) <= #{max_weight.to_f} THEN #{rate.to_f}"
        else
          "WHEN COALESCE(products.weight, 0) > #{min_weight.to_f} THEN #{rate.to_f}"
        end
      end

      <<~SQL.squish
        CASE
          WHEN COALESCE(products.weight, 0) <= 0 THEN 0
          #{clauses.join(' ')}
          ELSE 0
        END
      SQL
    end
  end
end
