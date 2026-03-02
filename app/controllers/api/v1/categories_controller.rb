module Api
  module V1
    class CategoriesController < ApplicationController
      include FavoriteHelper

      def index
        categories = Category.active
        categories = categories.popular if params[:is_popular] == 'true'
        categories = categories.top if params[:is_top] == 'true'
        categories = categories.custom if params[:is_custom] == 'true'

        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i

        categories = categories.page(page).per(per_page)

        render json: CategorySerializer.new(categories, {
          meta: {
            total: categories.total_count,
            page: page,
            per_page: per_page,
            total_pages: categories.total_pages
          }
        })
      end
      
      def show
        category = Category.includes(:seo_meta).find_by(ikea_id: params[:id])
        render json: CategorySerializer.new(category, {
          params: { city: current_city }
        })
      end

      def products
        category = Category.find_by(ikea_id: params[:id])
        return render json: { error: 'Category not found' }, status: :not_found unless category

        search_params = {
          min_price: params[:min_price],
          max_price: params[:max_price],
          sort: params[:sort],
          filters: params[:filters]
        }

        products_scope = Products::SearchService.new(category, search_params).call
        
        products = products_scope
                           .includes(:categories)
                           .page(params[:page])
                           .per(params[:per_page] || 50)

        render json: ProductTeaserSerializer.new(products, {
          params: { favorite_skus: current_favorite_skus },
          meta: {
            total: products.total_count,
            page: (params[:page] || 1).to_i,
            per_page: (params[:per_page] || 50).to_i,
            total_pages: products.total_pages,
            default_sort: category.default_sort,
            available_filters: category.available_filters || []
          }
        })
      end
      
      def popular
        categories = Category.popular
        render json: CategoryPopularSerializer.new(categories)
      end

      def top
        categories = Category.top
        render json: CategoryTopSerializer.new(categories)
      end

      def custom
        categories = Category.custom
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
