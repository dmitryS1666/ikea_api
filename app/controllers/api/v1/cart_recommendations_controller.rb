# frozen_string_literal: true

module Api
  module V1
    class CartRecommendationsController < ApplicationController
      def index
        products = ProductRecommendationsResolver.call(
          placement: :cart,
          limit: per_page,
          exclude_skus: exclude_skus
        )
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a

        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            root_categories_only: true,
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.size,
            placement: "cart"
          }
        })
      end

      private

      def per_page
        value = params[:per_page].to_i
        return ProductRecommendationsResolver::DEFAULT_LIMIT unless value.positive?

        value.clamp(1, 24)
      end

      def exclude_skus
        raw = params[:exclude_skus]
        Array(raw).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)
      end

      def serialization_params
        rates = {
          eur: ExchangeRate.fetch_or_create("EUR")&.rate_per_unit,
          pln: ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
        }

        calculator_settings = {
          "show_delivery_block_global" => CalculatorSetting.get("show_delivery_block_global"),
          "show_reviews_block_global" => CalculatorSetting.get("show_reviews_block_global"),
          "show_tips_block_global" => CalculatorSetting.get("show_tips_block_global"),
          "default_delivery_days" => CalculatorSetting.get("default_delivery_days"),
          "exchange_rate_buffer" => CalculatorSetting.get("exchange_rate_buffer")
        }

        {
          favorite_skus: [],
          active_promos: PromoCode.active_now.to_a,
          rates: rates,
          calculator_settings: calculator_settings
        }
      end
    end
  end
end
