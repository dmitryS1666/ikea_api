class SitemapsController < ApplicationController
  def show
    settings = FeedSetting.instance
    return head(:not_found) unless settings.base_url.present?

    sitemap = Sitemaps::Builder.call(settings: settings)
    
    expires_in 1.day, public: true
    render xml: sitemap
  end
end
