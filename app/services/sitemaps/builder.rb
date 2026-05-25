module Sitemaps
  class Builder
    attr_reader :settings, :base_url

    def initialize(settings:)
      @settings = settings
      @base_url = settings.base_url_root
    end

    def self.call(settings:)
      new(settings: settings).call
    end

    def call
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") do
          build_static_pages(xml)
          build_categories(xml)
          build_products(xml)
        end
      end.to_xml
    end

    private

    def build_static_pages(xml)
      add_url(xml, "/", priority: 1.0, changefreq: "daily")
    end

    def build_categories(xml)
      Category.active.find_each do |category|
        add_url(
          xml,
          "/category/#{category.ikea_id}",
          priority: 0.8,
          changefreq: "weekly",
          lastmod: category.updated_at
        )
      end
    end

    def build_products(xml)
      Product.active.with_available_stock.find_each do |product|
        add_url(
          xml,
          Products::PublicProductUrl.path(product),
          priority: 0.6,
          changefreq: "weekly",
          lastmod: product.updated_at
        )
      end
    end

    def add_url(xml, path, priority: 0.5, changefreq: "monthly", lastmod: nil)
      xml.url do
        xml.loc("#{base_url}#{path}")
        xml.lastmod(lastmod.to_date.iso8601) if lastmod
        xml.changefreq(changefreq)
        xml.priority(priority)
      end
    end
  end
end
