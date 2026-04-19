class SimilarProductsService
  def self.for(product:, limit: 8)
    return [] unless product

    scope = Product.with_available_stock.where.not(sku: product.sku)

    # Strategy is configurable from admin via CalculatorSetting.
    # Supported values:
    # - 'category' (default): similar items from same category
    # - 'category_collection': same category + same collection (if collection present)
    # - 'collection': same collection only (if present), fallback to category
    strategy = (CalculatorSetting.get('similar_products_strategy') || 'category').to_s

    case strategy
    when 'category_collection'
      if product.collection.present?
        scope = scope.where(category_id: product.category_id, collection: product.collection)
      else
        scope = scope.where(category_id: product.category_id)
      end
    when 'collection'
      if product.collection.present?
        scope = scope.where(collection: product.collection)
      else
        scope = scope.where(category_id: product.category_id)
      end
    else
      scope = scope.where(category_id: product.category_id)
    end

    scope.limit(limit)
  end
end
