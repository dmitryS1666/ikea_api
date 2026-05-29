# frozen_string_literal: true

module Api
  module V1
    class SearchController < ApplicationController
      include FavoriteHelper

      def suggest
        query = params[:q].to_s.strip
        page = normalized_page
        per_page = normalized_per_page
        first_page = page == 1

        service = Search::SuggestService.new(query: query, params: params, first_page: first_page)
        display_products = service.paginated_products
        category_records = service.category_records_for_page(display_products)

        log_search(query, display_products.total_count) if first_page && query.present?

        rates = exchange_rates
        calculator_settings = calculator_settings_payload
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        teaser_params = {
          favorite_skus: current_favorite_skus,
          active_promos: promos,
          promo_applicability: get_promo_applicability(display_products, promos),
          rates: rates,
          calculator_settings: calculator_settings,
          search_context: true,
          site_url: public_site_url
        }

        render json: {
          suggestions: service.suggestions,
          categories: CategoryTeaserSerializer.new(category_records).serializable_hash,
          products: ProductTeaserSerializer.new(display_products, { params: teaser_params }).serializable_hash,
          available_filters: service.available_filters(category_records),
          popular_queries: service.popular_queries.map { |entry| { query: entry.query, weight: entry.weight } },
          meta: {
            total: display_products.total_count,
            page: page,
            per_page: per_page,
            total_pages: display_products.total_pages
          }
        }
      end

      private

      def normalized_page
        page = params[:page].to_i
        page.positive? ? page : 1
      end

      def normalized_per_page
        per_page = params[:per_page].to_i
        per_page = 20 if per_page <= 0
        [per_page, 100].min
      end

      def exchange_rates
        {
          eur: ExchangeRate.fetch_or_create("EUR")&.rate_per_unit,
          pln: ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
        }
      end

      def calculator_settings_payload
        {
          "show_delivery_block_global" => CalculatorSetting.get("show_delivery_block_global"),
          "show_reviews_block_global" => CalculatorSetting.get("show_reviews_block_global"),
          "show_tips_block_global" => CalculatorSetting.get("show_tips_block_global"),
          "default_delivery_days" => CalculatorSetting.get("default_delivery_days"),
          "exchange_rate_buffer" => CalculatorSetting.get("exchange_rate_buffer")
        }
      end

      def log_search(query, results_count)
        SearchQueryLog.create!(
          customer: current_user,
          query: query,
          results_count: results_count
        )
      end
    end
  end
end
