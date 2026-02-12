module Products
  class SearchService
    def initialize(category, params = {})
      @category = category
      @params = params
      @scope = category.products_through_categories.active
    rescue NoMethodError
      @scope = category.products.active
    rescue
      @scope = Product.active
    end

    def call
      filter_by_price
      filter_by_attributes
      sort_results
      
      @scope.distinct
    end

    private

    def filter_by_price
      if @params[:min_price].present?
        @scope = @scope.where('products.price >= ?', @params[:min_price])
      end

      if @params[:max_price].present?
        @scope = @scope.where('products.price <= ?', @params[:max_price])
      end
    end

    def filter_by_attributes
      return unless @params[:filters].present? && @params[:filters].is_a?(Hash)

      @params[:filters].each do |filter_param, values|
        next if values.blank?
        
        # values can be a single string or an array
        value_ids = Array(values)
        
        @scope = @scope.joins(product_filter_values: :filter_value)
                       .joins('INNER JOIN filters ON filter_values.filter_id = filters.id')
                       .where(filters: { parameter: filter_param })
                       .where(filter_values: { value_id: value_ids })
      end
    end

    def sort_results
      sort_option = @params[:sort] || @category.try(:default_sort) || 'popular'

      case sort_option.to_s
      when 'cheapest'
        @scope = @scope.order('products.price ASC')
      when 'expensive'
        @scope = @scope.order('products.price DESC')
      when 'newest'
        @scope = @scope.order('products.created_at DESC')
      when 'popular'
        # Популярное: сначала те, у кого есть popularity_score, затем по рейтингу
        @scope = @scope.order(Arel.sql('products.popularity_score DESC, products.rating_weighted DESC, products.views_count DESC'))
      else
        @scope = @scope.order('products.id DESC')
      end
    end
  end
end
