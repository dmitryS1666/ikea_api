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
      return unless @category&.ikea_id

      @params[:filters].each do |filter_param, values|
        value_ids = Array(values).map(&:to_s).reject(&:blank?)
        next if value_ids.empty?

        subquery = ProductFilterValue
                     .where(category_id: @category.ikea_id, parameter: filter_param.to_s, value_id: value_ids)
                     .select(:product_id)

        @scope = @scope.where(id: subquery)
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
