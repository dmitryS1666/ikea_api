module Api
  module V1
    class HomepageController < ApplicationController
      def slider_main
        banners = HomeBanner.active
                           .main
                           .by_position
                           .includes(:category, :image_attachment)

        global_seo = GlobalSeoSetting.find_by(target_type: 'home')
        site_url = public_site_url

        render json: HomeBannerSerializer.new(banners, {
          meta: {
            seo: global_seo ? {
              title: global_seo.title_template,
              description: global_seo.description_template,
              keywords: global_seo.keywords_template,
              robots: global_seo.robots,
              seo_text: global_seo.seo_text,
              h1: global_seo.h1_template
            } : nil,
            structured_data: [
              Seo::StructuredData::OrganizationBuilder.build(site_url: site_url)
            ].compact
          }
        })
      end

      def slider_banners
        banners = HomeBanner.active
                           .secondary
                           .by_position
                           .includes(:category, :image_attachment)

        render json: HomeBannerSerializer.new(banners)
      end

      def recommendations
        products = ProductRecommendationsResolver.call(placement: :homepage, limit: per_page)
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a

        render json: ProductTeaserSerializer.new(products, {
          params: serialization_params.merge(
            active_promos: promos,
            promo_applicability: get_promo_applicability(products, promos)
          ),
          meta: {
            total: products.size,
            placement: 'homepage'
          }
        })
      end

      private

      def per_page
        value = params[:per_page].to_i
        return 8 unless value.positive?

        value.clamp(1, 24)
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
          favorite_skus: [],
          active_promos: PromoCode.active_now.to_a,
          rates: rates,
          calculator_settings: calculator_settings
        }
      end
    end
  end
end
