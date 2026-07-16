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
          params: seo_serialization_params,
          meta: {
            total: categories.total_count,
            page: page,
            per_page: per_page,
            total_pages: categories.total_pages
          }
        })
      end
      
      def show
        payload = Categories::ShowCache.fetch(
          ikea_id: params[:id],
          city: current_city,
          site_url: public_site_url
        )
        return render json: { error: "Category not found" }, status: :not_found if payload.blank?

        render json: payload
      end

      def products
        category = Category.find_by(ikea_id: params[:id])
        return render json: { error: 'Category not found' }, status: :not_found unless category
        per_page = normalized_per_page

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
                           .per(per_page)

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
            per_page: per_page,
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
        render json: CategorySerializer.new(categories, { params: seo_serialization_params })
      end
      
      def tree
        cache_key = "categories_tree_v4_#{current_city}"
        tree = Rails.cache.fetch(cache_key, expires_in: 12.hours) do
          categories = Category
            .where(is_deleted: false)
            .select(:id, :ikea_id, :translated_name, :cached_slug, :parent_ids, :top_position, :root_position, :name)
            .with_attached_icon
            .with_attached_pictogram

          Categories::TreeBuilder.new(categories, city_code: current_city).call
        end

        response = tree.deep_dup
        catalog_seo = Categories::CatalogSeoPayload.call
        response[:catalog_seo] = catalog_seo if catalog_seo.present?

        render json: response
      end
      
      def map
        # Кешируем карту категорий
        json = Rails.cache.fetch("categories_map_json_v3_#{current_city}", expires_in: 1.day) do
          categories = Category.active
                              .includes(:products_with_available_stock)
                              .with_attached_icon
                              .with_attached_background_image
                              .where.not(translated_name: nil)
                              .where.not(translated_name: '')
          
          CategoryMapSerializer.new(categories, {
            include: [],
            params: seo_serialization_params,
            meta: {
              total: categories.count,
              generated_at: Time.current.iso8601
            }
          }).serializable_hash.to_json
        end
        render json: json
      end

      private

      def normalized_per_page
        per_page = params[:per_page].to_i
        per_page = 20 if per_page <= 0
        [per_page, 100].min
      end
    end
  end
end
