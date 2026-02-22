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

    # Фильтрация по атрибутам через filters/filter_values удалена.
    # Доступные фильтры берутся из category.available_filters.

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
