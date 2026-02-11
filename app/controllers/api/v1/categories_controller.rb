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

        products = category.products
                           .includes(:category)
                           .page(params[:page])
                           .per(params[:per_page] || 50)

        render json: ProductSerializer.new(products, {
          include: [:category],
          meta: {
            total: products.total_count,
            page: params[:page] || 1,
            per_page: params[:per_page] || 50
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

