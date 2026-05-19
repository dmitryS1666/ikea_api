class RecommendedProductsService
  def self.call(limit: 8)
    skus = RecommendedProduct.active.ordered.limit(limit).pluck(:product_sku)
    return [] if skus.empty?

    # keep order
    products = Product.with_available_stock.where(sku: skus).index_by(&:sku)
    skus.filter_map { |sku| products[sku] }
  end
end
