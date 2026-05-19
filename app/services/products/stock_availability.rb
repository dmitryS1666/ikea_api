# frozen_string_literal: true

module Products
  # Единые правила «товар в наличии» для витрины и API.
  module StockAvailability
    MIN_QUANTITY = 1

    module_function

    def in_stock_quantity?(quantity)
      quantity.to_i >= MIN_QUANTITY
    end

    def product_in_stock?(product)
      product.present? && in_stock_quantity?(product.quantity)
    end

    def find_in_stock_product(raw_sku)
      product = Products::ListingSkuResolver.find_product(raw_sku)
      product_in_stock?(product) ? product : nil
    end

    def reference_sku(item)
      return item.to_s.strip.presence unless item.is_a?(Hash)

      (item["sku"] || item[:sku] || item["item_no"] || item[:item_no]).to_s.strip.presence
    end

    # Сохраняет порядок исходного списка; убирает SKU без товара в БД с quantity >= 1.
    def filter_skus_with_available_stock(skus)
      normalized = Array(skus).filter_map { |item| reference_sku(item) }.uniq
      return [] if normalized.empty?

      lookup_keys = normalized.flat_map { |sku| Products::ListingSkuResolver.aliases(sku) }.uniq
      in_stock_by_sku =
        Product.with_available_stock
               .where(sku: lookup_keys)
               .index_by { |product| product.sku.to_s }

      alias_to_canonical = {}
      in_stock_by_sku.each_value do |product|
        Products::ListingSkuResolver.aliases(product.sku).each do |alias_sku|
          alias_to_canonical[alias_sku.to_s] = product.sku.to_s
        end
      end

      normalized.filter_map { |sku| alias_to_canonical[sku] }
    end
  end
end
