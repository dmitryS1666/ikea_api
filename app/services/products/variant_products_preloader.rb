# frozen_string_literal: true

module Products
  # Builds one SKU lookup for every variant referenced by a product listing.
  # Without it Product#normalized_variants_for_api_full performs a product
  # query for every card in the page.
  class VariantProductsPreloader
    class << self
      def call(products)
        skus = Array(products).flat_map do |product|
          [product.sku, *product.normalized_variant_skus, *payload_skus(product.variants_payload)]
        end
        lookup_skus = skus
          .compact
          .flat_map { |sku| Products::ListingSkuResolver.aliases(sku) }
          .map(&:to_s)
          .reject(&:blank?)
          .uniq
        return {} if lookup_skus.empty?

        Product
          .where(sku: lookup_skus)
          .includes(:category, :product_filter_values)
          .each_with_object({}) do |product, lookup|
            Products::ListingSkuResolver.aliases(product.sku).each do |alias_sku|
              lookup[alias_sku.to_s] = product
            end
          end
      end

      private

      def payload_skus(raw_payload)
        return [] if raw_payload.blank?

        payload = JSON.parse(raw_payload.to_s)
        groups = payload.is_a?(Array) ? payload : [payload]

        groups.flat_map do |group|
          next [] unless group.is_a?(Hash)

          Array(group["data"] || group[:data]).filter_map do |variant|
            next unless variant.is_a?(Hash)

            item = variant["item"] || variant[:item]
            item["sku"] || item[:sku] if item.is_a?(Hash)
          end
        end
      rescue JSON::ParserError, TypeError
        []
      end
    end
  end
end
