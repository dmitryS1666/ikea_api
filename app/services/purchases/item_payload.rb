module Purchases
  class ItemPayload
    def self.call(order_item:, order:, product:, serializer_params: Purchases::ProductCardPayload.default_params)
      unit_price = order_item.price.to_f
      public_sku = Product.public_sku(order_item.product_sku)

      {
        id: order_item.id,
        order_id: order.id,
        status: order.frontend_status,
        purchased_at: order.purchased_at&.iso8601,
        product_sku: public_sku,
        sku: public_sku,
        quantity: order_item.quantity,
        price_byn: format_byn(unit_price),
        unit_price_byn: format_byn(unit_price),
        total_price_byn: format_byn(unit_price * order_item.quantity),
        product: Purchases::ProductCardPayload.call(product, params: serializer_params)
      }
    end

    def self.format_byn(value)
      format("%.2f", value.to_f)
    end
    private_class_method :format_byn
  end
end
