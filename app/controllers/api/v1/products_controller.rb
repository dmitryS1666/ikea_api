module Api
  module V1
    class ProductsController < ApplicationController
      before_action :authenticate_user, except: [:index, :show, :bestsellers, :popular, :categories]
      
      def index
        products = Product.includes(:category)
        products = products.by_rating if params[:sort] == 'rating'
        products = products.page(params[:page]).per(params[:per_page] || 50)
        
        render json: ProductSerializer.new(products, {
          meta: {
            total: products.total_count,
            page: params[:page] || 1,
            per_page: params[:per_page] || 50,
            sort: params[:sort]
          }
        })
      end
      
      def show
        product = Product.includes(:seo_meta).find_by(sku: params[:sku])
        render json: ProductSerializer.new(product, {
          params: { detail: true, city: current_city }
        })
      end
      
      def bestsellers
        products = Product.bestsellers
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductSerializer.new(products, {
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end
      
      def popular
        products = Product.popular
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductSerializer.new(products, {
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def categories
        collection_name = params[:collection]
        return render json: { error: 'Collection parameter is required' }, status: :bad_request if collection_name.blank?

        categories = Category.active
                             .joins(:products_through_categories)
                             .where(products: { collection: collection_name })
                             .distinct

        render json: CategorySerializer.new(categories)
      end
    end
  end
end

