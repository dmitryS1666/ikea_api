# frozen_string_literal: true

class OrderReorderService
  def self.call(order:, user: nil)
    new(order: order, user: user).call
  end

  def initialize(order:, user: nil)
    @order = order
    @user = user || order.user
  end

  def call
    return { skipped: true, reason: :no_user } unless user

    cart = user.cart || user.create_cart
    updated_items = []
    missing_items = []
    adjusted_items = []

    Cart.transaction do
      order.order_items.each do |item|
        product = Product.with_available_stock.find_by(sku: item.product_sku)
        unless product
          missing_items << item.product_sku
          next
        end

        requested_quantity = item.quantity.to_i
        available_quantity = product.quantity.to_i
        target_quantity = [requested_quantity, available_quantity].min

        if target_quantity <= 0
          missing_items << item.product_sku
          next
        end

        cart_item = cart.cart_items.find_or_initialize_by(product_sku: item.product_sku)
        cart_item.quantity = target_quantity
        cart_item.save!
        updated_items << item.product_sku

        if target_quantity < requested_quantity
          adjusted_items << {
            sku: item.product_sku,
            requested: requested_quantity,
            available: target_quantity
          }
        end
      end

      cart.touch_expiration!
      CartAutoPromoService.call(cart: cart)
    end

    {
      added_skus: updated_items,
      updated_skus: updated_items,
      missing_skus: missing_items,
      adjusted_items: adjusted_items,
      has_missing: missing_items.any? || adjusted_items.any?
    }
  end

  private

  attr_reader :order, :user
end
