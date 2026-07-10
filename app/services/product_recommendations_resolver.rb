class ProductRecommendationsResolver
  DEFAULT_LIMIT = 8

  def self.call(placement:, limit: DEFAULT_LIMIT, exclude_skus: [])
    new(
      placement: placement,
      limit: limit,
      exclude_skus: exclude_skus
    ).call
  end

  def initialize(placement:, limit:, exclude_skus: [])
    @placement = placement.to_s
    @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
    @exclude_skus = Array(exclude_skus).map(&:to_s)
  end

  def call
    return [] unless @placement == "cart"

    setting = ProductRecommendationSetting.active.cart.first
    return [] unless setting

    products =
      case setting.source_type
      when "category"
        resolve_from_category(setting.category_id)
      when "sku_list", "product_list"
        resolve_from_skus(setting.product_skus)
      else
        []
      end

    products.reject { |product| @exclude_skus.include?(product.sku.to_s) }
            .first(@limit)
  end

  private

  def resolve_from_skus(skus)
    normalized_skus = Array(skus).map(&:to_s).map(&:strip).reject(&:blank?)
    return [] if normalized_skus.empty?

    products_by_sku = Product.with_available_stock.where(sku: normalized_skus).index_by { |product| product.sku.to_s }

    normalized_skus.filter_map do |sku|
      products_by_sku[sku]
    end
  end

  def resolve_from_category(category_id)
    return [] if category_id.blank?

    Product.with_available_stock.where(category_id: category_id)
           .order(updated_at: :desc)
           .limit(@limit + @exclude_skus.size)
           .to_a
  end
end
