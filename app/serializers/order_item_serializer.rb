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
    if order_item.respond_to?(:image_url) && order_item.image_url.present?
      order_item.image_url
    else
      product = order_item.product
      local = Array(product&.local_images).find(&:present?)
      remote = Array(product&.images).find(&:present?)
      local.presence || remote
    end
  end
end
