# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrderReorderService do
  let(:user) { create(:user) }
  let(:order) { create(:order, user: user) }
  let!(:product) { create(:product, sku: "90205097", quantity: 5) }

  before do
    create(:order_item, order: order, product_sku: product.sku, quantity: 2, price: 10.0)
  end

  it "adds order items to the user cart" do
    result = described_class.call(order: order)

    cart_item = user.reload.cart.cart_items.find_by(product_sku: product.sku)
    expect(cart_item.quantity).to eq(2)
    expect(result[:added_skus]).to eq([product.sku])
    expect(result[:has_missing]).to be(false)
  end

  it "skips when order has no user" do
    order.update!(user: nil)

    result = described_class.call(order: order)

    expect(result).to eq({ skipped: true, reason: :no_user })
  end

  it "is idempotent and does not duplicate quantities on repeated clicks" do
    described_class.call(order: order)
    described_class.call(order: order)

    cart_item = user.reload.cart.cart_items.find_by!(product_sku: product.sku)
    expect(cart_item.quantity).to eq(2)
  end

  it "caps repeated quantity by current stock and reports the adjustment" do
    product.update!(quantity: 1)

    result = described_class.call(order: order)

    cart_item = user.reload.cart.cart_items.find_by!(product_sku: product.sku)
    expect(cart_item.quantity).to eq(1)
    expect(result[:adjusted_items]).to eq([
      { sku: product.sku, requested: 2, available: 1 }
    ])
    expect(result[:has_missing]).to be(true)
  end

end
