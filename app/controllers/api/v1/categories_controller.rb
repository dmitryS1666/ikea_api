module Api
  module V1
    class CategoriesController < ApplicationController
      include FavoriteHelper

      def index
        categories = Category.active.includes(:seo_meta, icon_attachment: :blob, background_image_attachment: :blob)
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
        category = Category.includes(:seo_meta).with_attached_icon.with_attached_background_image.find_by(ikea_id: params[:id])
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
        
        rates = {
          eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
          pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
        }

        products = products_scope
                           .includes(:categories, :category_products, :seo_meta)
                           .page(params[:page])
                           .per(params[:per_page] || 50)

        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        
        calculator_settings = {
          'show_delivery_block_global' => CalculatorSetting.get('show_delivery_block_global'),
          'show_reviews_block_global' => CalculatorSetting.get('show_reviews_block_global'),
          'show_tips_block_global' => CalculatorSetting.get('show_tips_block_global'),
          'default_delivery_days' => CalculatorSetting.get('default_delivery_days'),
          'exchange_rate_buffer' => CalculatorSetting.get('exchange_rate_buffer')
        }

        render json: ProductTeaserSerializer.new(products, {
          params: { 
            favorite_skus: current_favorite_skus,
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos),
            rates: rates,
            calculator_settings: calculator_settings
          },
          meta: {
            total: products.total_count,
            page: (params[:page] || 1).to_i,
            per_page: (params[:per_page] || 50).to_i,
            total_pages: products.total_pages,
            default_sort: category.default_sort
          }
        })
      end
      
      def popular
        categories = Category.popular.includes(:seo_meta).with_attached_icon.with_attached_background_image
        render json: CategoryPopularSerializer.new(categories)
      end

      def top
        categories = Category.top.includes(:seo_meta).with_attached_icon.with_attached_background_image
        render json: CategoryTopSerializer.new(categories)
      end

      def custom
        categories = Category.custom.includes(:seo_meta).with_attached_icon.with_attached_background_image
        render json: CategorySerializer.new(categories)
      end
      
      def tree
        tree = Rails.cache.fetch("categories_tree_v1", expires_in: 12.hours) do
          categories = Category
            .where(is_deleted: false)
            .select(:id, :ikea_id, :translated_name, :cached_slug, :parent_ids, :top_position, :root_position)
            .with_attached_icon
            .with_attached_pictogram
      
          Categories::TreeBuilder.new(categories).call
        end
      
        render json: tree
      end
      
      def map
        # Кешируем карту категорий
        json = Rails.cache.fetch('categories_map_json', expires_in: 1.day) do
          categories = Category.active
                              .includes(:products)
                              .with_attached_icon
                              .with_attached_background_image
                              .where.not(translated_name: nil)
                              .where.not(translated_name: '')
          
          CategoryMapSerializer.new(categories, {
            include: [],
            meta: {
              total: categories.count,
              generated_at: Time.current.iso8601
            }
          }).serializable_hash.to_json
        end
        render json: json
      end
    end
  end
end
