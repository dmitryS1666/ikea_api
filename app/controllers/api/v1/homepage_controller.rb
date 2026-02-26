module Api
  module V1
    class HomepageController < ApplicationController
    def slider_main
      banners = HomeBanner.active
                         .main
                         .by_position
                         .includes(:category, :image_attachment)
      
      # Добавляем глобальные SEO настройки для главной
      global_seo = GlobalSeoSetting.find_by(target_type: 'home')
      
      render json: HomeBannerSerializer.new(banners, {
        meta: {
          seo: global_seo ? {
            title: global_seo.title_template,
            description: global_seo.description_template,
            keywords: global_seo.keywords_template,
            robots: global_seo.robots,
            seo_text: global_seo.seo_text
          } : nil
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
    end
  end
end
