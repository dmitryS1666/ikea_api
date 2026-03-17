module Api
  module V1
    class ProductsController < ApplicationController
      include FavoriteHelper
      before_action :authenticate_user, except: [:index, :show, :bestsellers, :popular, :new_arrivals, :recommended, :categories]
      
      def index
        products = Product.includes(:category)
        products = products.by_rating if params[:sort] == 'rating'
        products = products.page(params[:page]).per(params[:per_page] || 50)
        
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params,
          meta: {
            total: products.total_count,
            page: params[:page] || 1,
            per_page: params[:per_page] || 50,
            sort: params[:sort]
          }
        })
      end
      
      def show
        product = Product.includes(:seo_meta, :category).find_by!(sku: params[:sku])
        
        render json: ProductSerializer.new(product, {
          params: serialization_params.merge(detail: true, city: current_city)
        })
      end
      
      def bestsellers
        products = Product.bestsellers
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params,
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def new_arrivals
        products = Product.new_arrivals
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params,
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def recommended
        products = Product.recommended
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params,
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
        
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params,
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def categories
        # ... existing implementation ...
      end

      private

      def serialization_params
        {
          favorite_skus: current_favorite_skus,
          active_promos: PromoCode.active_now.to_a,
          rates: {
            eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
            pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
          }
        }
      end
    end
  end
end
