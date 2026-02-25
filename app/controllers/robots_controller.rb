class RobotsController < ApplicationController
  def show
    base_url = FeedSetting.instance.base_url_root
    body = <<~ROBOTS
      User-agent: *
      Allow: /
      Disallow: /admin/
      Disallow: /api/v1/account/
      Disallow: /api/v1/cart/
      Disallow: /api/v1/checkout/

      Sitemap: #{base_url}/sitemap.xml
    ROBOTS

    render plain: body, content_type: "text/plain"
  end
end
