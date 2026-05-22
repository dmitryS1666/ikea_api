# frozen_string_literal: true

module Seo
  module PublicSiteUrl
    module_function

    def resolve(request = nil)
      explicit = ENV["PUBLIC_SITE_URL"].presence
      return explicit.chomp("/") if explicit

      return request.base_url.chomp("/") if request&.base_url.present?

      "https://ikeya.by"
    end
  end
end
