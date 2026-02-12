module Api
  module V1
    class CategoriesController < ApplicationController
      def index
        categories = Category.active
        categories = categories.popular if params[:is_popular] == 'true'
        
        render json: CategorySerializer.new(categories)
      end
      
      def show
        category = Category.find_by(ikea_id: params[:id])
        render json: CategorySerializer.new(category)
      end

      def products
        category = Category.find_by(ikea_id: params[:id])
        return render json: { error: 'Category not found' }, status: :not_found unless category

        search_params = {
          min_price: params[:min_price],
          max_price: params[:max_price],
          sort: params[:sort],
          filters: params[:filters] # Ожидаем Hash: { color: ['red', 'blue'], material: 'wood' }
        }

        products_scope = Products::SearchService.new(category, search_params).call
        
        products = products_scope
                           .includes(:categories, :filter_values)
                           .page(params[:page])
                           .per(params[:per_page] || 50)

        # Собираем доступные фильтры для текущей категории
        # Это поможет фронтенду отображать только актуальные значения
        available_filters_data = category.products_through_categories
                                    .joins(filter_values: :filter)
                                    .select('filters.parameter, filters.name_ru as filter_name, filter_values.value_id, filter_values.name_ru as value_name')
                                    .distinct

        # Группируем фильтры для удобства фронтенда
        filters_meta = available_filters_data.group_by(&:parameter).map do |param, values|
          {
            parameter: param,
            name: values.first.filter_name,
            values: values.map { |v| { id: v.value_id, name: v.value_name } }
          }
        end

        render json: ProductSerializer.new(products, {
          include: [:categories],
          meta: {
            total: products.total_count,
            page: (params[:page] || 1).to_i,
            per_page: (params[:per_page] || 50).to_i,
            total_pages: products.total_pages,
            default_sort: category.default_sort,
            available_filters: filters_meta
          }
        })
      end
      
      def popular
        categories = Category.popular
        render json: CategorySerializer.new(categories)
      end

      def header_menu
        categories = Category.in_header_menu
        render json: CategorySerializer.new(categories)
      end
      
      def tree
        # Простая реализация дерева категорий
        categories = Category.active.includes(:products)
        render json: CategorySerializer.new(categories)
      end
      
      def map
        # Карта категорий: переведенное имя + ссылка + продукты
        categories = Category.active
                            .includes(:products)
                            .where.not(translated_name: nil)
                            .where.not(translated_name: '')
        
        render json: CategoryMapSerializer.new(categories, {
          include: [],
          meta: {
            total: categories.count,
            generated_at: Time.current.iso8601
          }
        })
      end
    end
  end
end

