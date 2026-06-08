class OrderItemSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :product_sku, :quantity

  attribute :price_byn do |order_item|
    if order_item.respond_to?(:price_byn)
      order_item.price_byn
    else
      order_item.price.to_f.round(2)
    end
  end

  attribute :name do |order_item|
    if order_item.respond_to?(:name) && order_item.name.present?
      order_item.name
    else
      order_item.product&.small_desc_name.presence || order_item.product&.name
    end
  end

  attribute :image_url do |order_item|
    public_image_url(order_item)
  end

  class << self
    def public_image_url(order_item)
      snapshot = order_item.image_url if order_item.respond_to?(:image_url)
      snapshot_url = first_public_image_url(snapshot)
      return snapshot_url if snapshot_url.present?

      product = order_item.product
      local_url = first_public_image_url(product&.local_images)
      return local_url if local_url.present?

      first_public_image_url(product&.images)
    end

    private

    def first_public_image_url(value)
      ProductLocalImages.expand_paths(value).find(&:present?)
    rescue StandardError => e
      Rails.logger.warn("OrderItemSerializer.image_url: failed to normalize image URL: #{e.class} #{e.message}")
      nil
    end
  end
end
