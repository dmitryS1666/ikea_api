module Api
  module V1
    module Content
      class ArticlesController < ApplicationController
        include FavoriteHelper

        def index
          articles = ContentArticle.visible
          articles = apply_filters(articles)
          articles = articles.includes(:content_article_products, :content_article_categories, :seo_meta)

          paged = articles.page(current_page).per(per_page)
          body_block_products_map = preload_body_block_products_for_articles(paged)

          render json: ContentArticleSerializer.new(paged, {
            params: {
              body_block_products_map: body_block_products_map,
              product_serializer_params: product_teaser_serialization_params(body_block_products_map.values)
            },
            meta: {
              total: paged.total_count,
              page: current_page,
              per_page: per_page
            }
          })
        end

        def show
          slug = params[:slug] || params[:id]
          article = ContentArticle.visible.includes(:seo_meta).find_by!(slug: slug)
          article_products = article.content_article_products.order(:position)
          article_categories = article.content_article_categories.order(:position)

          linked_products_map = Product.with_available_stock.where(sku: article_products.pluck(:product_sku)).index_by(&:sku)
          body_block_products_map = preload_body_block_products_for_articles([article])
          categories_map = Category.where(ikea_id: article_categories.pluck(:category_id)).index_by(&:ikea_id)

          render json: ContentArticleSerializer.new(article, {
            params: {
              detail: true,
              linked_products_ordered: article_products,
              linked_products_map: linked_products_map,
              linked_categories_ordered: article_categories,
              linked_categories_map: categories_map,
              body_block_products_map: body_block_products_map,
              product_serializer_params: product_teaser_serialization_params(body_block_products_map.values)
            }
          })
        end

        private

        def apply_filters(scope)
          scope = scope.where(content_type: ContentArticle.content_types[params[:content_type]]) if params[:content_type].present? && ContentArticle.content_types.key?(params[:content_type])
          scope = scope.where(pinned: true) if params[:pinned_only] == 'true'
          scope = scope.with_component(params[:component]) if params[:component].present?
          scope = scope.with_project(params[:project]) if params[:project].present?
          
          rubric = params[:rubric] || params[:tag]
          scope = scope.with_rubric(rubric) if rubric.present?

          if params[:product_sku].present?
            product = Product.with_available_stock.find_by(sku: params[:product_sku])
            scope = scope.relevant_for_product(product) if product
          end

          scope = scope.for_category_id(params[:category_id]) if params[:category_id].present?
          scope
        end

        def preload_body_block_products_for_articles(articles)
          product_skus = Array.wrap(articles).flat_map do |article|
            Array.wrap(article.body_blocks).flat_map do |block|
              next [] unless block["type"] == "products_grid"

              Array.wrap(block["slider_product_skus"]).map(&:to_s).map(&:strip).reject(&:blank?)
            end
          end.uniq

          return {} if product_skus.empty?

          Product.with_available_stock.where(sku: product_skus)
                 .includes(:category, :category_products, :seo_meta)
                 .index_by(&:sku)
        end

        def product_teaser_serialization_params(products)
          products = Array.wrap(products).compact
          promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
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
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos),
            rates: rates,
            calculator_settings: calculator_settings
          }
        end

        def current_page
          params[:page].to_i.positive? ? params[:page].to_i : 1
        end

        def per_page
          per = params[:per_page].to_i
          return 20 if per.zero?

          per.clamp(1, 100)
        end
      end
    end
  end
end
