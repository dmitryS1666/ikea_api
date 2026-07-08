module Products
  class FeaturedTabProductsResolver
    Result = Struct.new(:products, :category_id_overrides, keyword_init: true)

    def self.call(list_key:)
      new(list_key: list_key).call
    end

    def initialize(list_key:)
      @list_key = list_key.to_s
    end

    def call
      tabs = FeaturedProductTab.active.where(list_key: @list_key).ordered.to_a
      return nil if tabs.empty?

      ordered_skus = []
      category_id_overrides = {}

      tabs.each do |tab|
        next if tab.category_id.blank?

        Array(tab.product_skus).each do |sku|
          normalized = sku.to_s.strip
          next if normalized.blank?
          next if category_id_overrides.key?(normalized)

          ordered_skus << normalized
          category_id_overrides[normalized] = tab.category_id.to_s
        end
      end

      products_by_sku = Product.with_available_stock.where(sku: ordered_skus).index_by { |product| product.sku.to_s }
      ordered_products = ordered_skus.filter_map { |sku| products_by_sku[sku] }

      active_overrides = category_id_overrides.slice(*ordered_products.map { |product| product.sku.to_s })
      Result.new(products: ordered_products, category_id_overrides: active_overrides)
    end
  end
end
