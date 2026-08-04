# frozen_string_literal: true

module Sitemaps
  class Builder
    STATIC_PAGES = [
      { path: "/", priority: 1.0, changefreq: "daily" },
      { path: "/catalog/", priority: 0.9, changefreq: "daily" },
      { path: "/about/", priority: 0.5, changefreq: "monthly" },
      { path: "/blog/", priority: 0.7, changefreq: "weekly" },
      { path: "/partner/", priority: 0.4, changefreq: "monthly" },
      { path: "/services/", priority: 0.5, changefreq: "monthly" },
      { path: "/pvz/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/delivery/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/payment/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/returns/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/customs/", priority: 0.6, changefreq: "monthly" },
      { path: "/help/how-to-order/", priority: 0.6, changefreq: "monthly" }
    ].freeze

    attr_reader :settings, :base_url

    def initialize(settings:)
      @settings = settings
      @base_url = settings.base_url_root
      @seen_paths = {}
    end

    def self.call(settings:)
      new(settings: settings).call
    end

    def call
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") do
          build_static_pages(xml)
          build_legal_pages(xml)
          build_categories(xml)
          build_seo_catalog_pages(xml)
          build_articles(xml)
          build_products(xml)
        end
      end.to_xml
    end

    private

    def build_static_pages(xml)
      STATIC_PAGES.each do |page|
        add_url(xml, page[:path], priority: page[:priority], changefreq: page[:changefreq])
      end
    end

    def build_legal_pages(xml)
      LegalPage.for_public_api.find_each do |page|
        add_url(
          xml,
          "/help/#{page.slug}/",
          priority: 0.4,
          changefreq: "monthly",
          lastmod: page.updated_at
        )
      end
    end

    def build_categories(xml)
      categories = Category.active.to_a
      categories_index = categories.index_by { |category| category.ikea_id.to_s }

      categories.each do |category|
        path = category.catalog_url(categories_index)
        next if path.blank?

        add_url(
          xml,
          path,
          priority: 0.8,
          changefreq: "weekly",
          lastmod: category.updated_at
        )
      end
    end

    def build_seo_catalog_pages(xml)
      SeoCatalogPage.for_sitemap.find_each do |page|
        add_url(
          xml,
          seo_catalog_public_path(page),
          priority: 0.8,
          changefreq: "weekly",
          lastmod: page.updated_at
        )
      end
    end

    def build_articles(xml)
      ContentArticle.visible.find_each do |article|
        add_url(
          xml,
          "/blog/#{article.slug}/",
          priority: 0.6,
          changefreq: "weekly",
          lastmod: article.updated_at || article.published_at
        )
      end
    end

    def build_products(xml)
      Product.with_available_stock.find_each do |product|
        add_url(
          xml,
          product_public_path(product),
          priority: 0.6,
          changefreq: "weekly",
          lastmod: product.updated_at
        )
      end
    end

    def product_public_path(product)
      core = product.public_sku.presence || product.sku.to_s
      slug = product.slug.to_s.presence || core
      normalize_path("/product/#{slug}-#{core}/")
    end

    # На фронте SEO-подборки живут как /catalog/<slug>/ (без /seo/).
    def seo_catalog_public_path(page)
      raw = page.canonical_path.presence || page.path.presence || "/catalog/#{page.slug}"
      raw = raw.to_s.sub(%r{\A/catalog/seo/}, "/catalog/")
      normalize_path(raw)
    end

    def add_url(xml, path, priority: 0.5, changefreq: "monthly", lastmod: nil)
      normalized = normalize_path(path)
      return if normalized.blank?
      return if @seen_paths[normalized]

      @seen_paths[normalized] = true

      xml.url do
        xml.loc("#{base_url}#{normalized == '/' ? '/' : normalized}")
        xml.lastmod(lastmod.to_date.iso8601) if lastmod
        xml.changefreq(changefreq)
        xml.priority(priority)
      end
    end

    def normalize_path(path)
      value = path.to_s.strip
      return "/" if value.blank? || value == "/"

      value = "/#{value}" unless value.start_with?("/")
      value = value.split("?", 2).first.to_s
      value = value.split("#", 2).first.to_s
      value.end_with?("/") ? value : "#{value}/"
    end
  end
end
