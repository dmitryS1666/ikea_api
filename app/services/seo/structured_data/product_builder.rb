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

        {
          "@context" => "https://schema.org",
          "@type" => "Product",
          "name" => SeoHelper.render_template_string("{{full_name}}", product, city_code).presence || product.name.to_s.presence || product.sku,
          "description" => meta[:description],
          "sku" => product.public_sku,
          "mpn" => product.item_no.presence || product.public_sku,
          "image" => images.presence,
          "url" => product_page_url,
          "offers" => {
            "@type" => "Offer",
            "url" => product_page_url,
            "priceCurrency" => "BYN",
            "price" => price_byn,
            "availability" => availability_url,
            "itemCondition" => "https://schema.org/NewCondition"
          }.compact
        }.compact
      end

      private

      attr_reader :product, :site_url, :city_code

      def product_page_url
        core = product.sku.to_s.sub(/\As/i, "")
        slug = product.slug.presence || core
        "#{site_url}/product/#{slug}-#{core}/"
      end

      def offer_price_byn
        pln = product.price.to_f
        return nil unless pln.positive?

        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit.to_f
        return nil unless pln_rate.positive?

        PriceCalculationService.product_storefront_price_byn(
          pln,
          weight_kg: product.packaging_weight_kg.to_f,
          delivery_pln: product.delivery_cost.to_f,
          pln_rate: pln_rate,
          buffer: PriceCalculationService.exchange_rate_buffer
        )
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
