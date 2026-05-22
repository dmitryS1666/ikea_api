# frozen_string_literal: true

module Seo
  module StructuredData
    class OrganizationBuilder
      DEFAULT_NAME = "IKEYA"
      DEFAULT_DESCRIPTION = "Интернет-магазин товаров ИКЕА в Беларуси"

      def self.build(site_url:)
        new(site_url: site_url).build
      end

      def initialize(site_url:)
        @site_url = site_url.to_s.chomp("/")
      end

      def build
        {
          "@context" => "https://schema.org",
          "@type" => "Organization",
          "name" => ENV.fetch("ORGANIZATION_NAME", DEFAULT_NAME),
          "url" => site_url,
          "logo" => logo_url,
          "description" => ENV.fetch("ORGANIZATION_DESCRIPTION", DEFAULT_DESCRIPTION)
        }.compact
      end

      private

      attr_reader :site_url

      def logo_url
        raw = ENV["ORGANIZATION_LOGO_URL"].presence
        return nil if raw.blank?

        raw.start_with?("http") ? raw : "#{site_url}#{raw.start_with?('/') ? '' : '/'}#{raw}"
      end
    end
  end
end
