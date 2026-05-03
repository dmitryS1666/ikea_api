module Api
  module V1
    class ProductsController < ApplicationController
      include FavoriteHelper
      before_action :authenticate_user, except: [:index, :show, :bestsellers, :popular, :new_arrivals, :recommended, :categories]
      
      def index
        products = Product.with_available_stock.includes(:category, :seo_meta, :category_products)
        products = apply_sort(products, params[:sort])
        products = products.page(params[:page]).per(params[:per_page] || 50)
      
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.total_count,
            page: params[:page] || 1,
            per_page: params[:per_page] || 50,
            sort: params[:sort]
          }
        })
      end
      
      def show
        resolved = Products::ListingSkuResolver.find_product(params[:sku])
        scope =
          Product.includes(
            :seo_meta,
            :category_products,
            category: :category_related_product_list,
            categories: :category_related_product_list
          )
        product =
          if resolved
            scope.find(resolved.id)
          else
            scope.find_by!(sku: params[:sku])
          end
        
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductSerializer.new(product, {
          params: serialization_params.merge(
            detail: true, 
            city: current_city,
            active_promos: promos,
            promo_applicability: get_promo_applicability([product], promos)
          )
        })
      end
      
      def bestsellers
        products = Product.bestsellers.with_available_stock
                         .includes(:category, :seo_meta, :category_products)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def new_arrivals
        products = Product.new_arrivals.with_available_stock
                         .includes(:category, :seo_meta, :category_products)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end

      def recommended
        products = Product.recommended.with_available_stock
                         .includes(:category, :seo_meta, :category_products)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end
      
      def popular
        products = Product.popular.with_available_stock
                         .includes(:category, :seo_meta, :category_products)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
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

      def apply_sort(scope, sort)
        case sort
        when 'rating'
          scope.by_rating
        when 'cheapest'
          scope.cheapest_first
        when 'expensive'
          scope.expensive_first
        else
          scope
        end
      end

      def serialization_params
        rates = {
          eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
          pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
        }
        
        calculator_settings = {
          'show_delivery_block_global' => CalculatorSetting.get('show_delivery_block_global'),
          'show_reviews_block_global' => CalculatorSetting.get('show_reviews_block_global'),
          'show_tips_block_global' => CalculatorSetting.get('show_tips_block_global'),
          'default_delivery_days' => CalculatorSetting.get('default_delivery_days'),
          'exchange_rate_buffer' => CalculatorSetting.get('exchange_rate_buffer')
        }

        {
          favorite_skus: current_favorite_skus,
          active_promos: PromoCode.active_now.to_a,
          rates: rates,
          calculator_settings: calculator_settings
        }
      end
    end
  end
end
