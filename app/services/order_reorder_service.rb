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
    added_items = []
    missing_items = []

    order.order_items.each do |item|
      product = Product.with_available_stock.find_by(sku: item.product_sku)
      if product
        cart_item = cart.cart_items.find_or_initialize_by(product_sku: item.product_sku)
        cart_item.quantity = (cart_item.quantity || 0) + item.quantity
        cart_item.save!
        added_items << item.product_sku
      else
        missing_items << item.product_sku
      end
    end

    {
      added_skus: added_items,
      missing_skus: missing_items,
      has_missing: missing_items.any?
    }
  end

  private

  attr_reader :order, :user
end
