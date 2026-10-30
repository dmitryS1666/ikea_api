# frozen_string_literal: true

module Seo
  module StructuredData
    class ProductBuilder
      def self.build(product, site_url:, city_code: nil)
        new(product, site_url: site_url, city_code: city_code).build
      end

      def initialize(product, site_url:, city_code: nil)
        @product = product
        @site_url = site_url.to_s.chomp("/")
        @city_code = city_code
      end

      def build
        return nil unless product

        meta = SeoHelper.meta_for(product, city_code)
        price_byn = offer_price_byn
        images = ProductLocalImages.expand_paths(product.local_images).first(10)

        page_url = product_page_url
        payload = {
          "@context" => "https://schema.org",
          "@type" => "Product",
          "name" => SeoHelper.render_template_string("{{full_name}}", product, city_code).presence || product.name.to_s.presence || product.sku,
          "description" => meta[:description],
          "sku" => product.public_sku,
          "mpn" => product.item_no.presence || product.public_sku,
          "image" => images.presence,
          "url" => page_url,
          "offers" => {
            "@type" => "Offer",
            "url" => page_url,
            "priceCurrency" => "BYN",
            "price" => price_byn,
            "availability" => availability_url,
            "itemCondition" => "https://schema.org/NewCondition"
          }.compact
        }.compact

        payload["offers"] = rewrite_offer_urls(payload["offers"], page_url) if payload["offers"]
        payload
      end

      private

      attr_reader :product, :site_url, :city_code

      def product_page_url
        core = product.sku.to_s.sub(/\As/i, "")
        slug = product.slug.presence || core
        "#{Seo::PublicSiteUrl.coerce(site_url)}/product/#{slug}-#{core}/"
      end

      def rewrite_offer_urls(offers, page_url)
        case offers
        when Array
          offers.map { |offer| rewrite_offer_urls(offer, page_url) }
        when Hash
          rewritten = offers.deep_dup
          type = rewritten["@type"].to_s
          rewritten["url"] = page_url if type.include?("Offer") || rewritten.key?("url")
          if rewritten["offers"]
            rewritten["offers"] = rewrite_offer_urls(rewritten["offers"], page_url)
          end
          rewritten
        else
          offers
        end
      end

      def offer_price_byn
        breakdown = PriceCalculationService.for_product(product)
        return nil unless breakdown[:pricing_available]

        Pricing::Money.to_f_round2(breakdown[:card_price_byn])
      end

      def availability_url
        if product.available_in_stock?
          "https://schema.org/InStock"
        else
          "https://schema.org/OutOfStock"
        end
      end
    end
  end
end
