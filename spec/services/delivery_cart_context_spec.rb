require "rails_helper"

RSpec.describe DeliveryCartContext do
  let(:user) { create(:user) }
  let(:cart) { create(:cart) }
  let!(:product_a) do
    create(:product, sku: "CTX-A", quantity: 10, price: 50.0, weight: 2.0, package_volume: 0.01,
           package_dimensions: "10x10x10", dimensions: "10x10x10", full_attributes: {})
  end
  let!(:product_b) do
    create(:product, sku: "CTX-B", quantity: 10, price: 80.0, weight: 3.0, package_volume: 0.01,
           package_dimensions: "10x10x10", dimensions: "10x10x10", full_attributes: {})
  end

  before do
    create(:cart_item, cart: cart, product_sku: "CTX-A", quantity: 2)
    create(:cart_item, cart: cart, product_sku: "CTX-B", quantity: 1)
  end

  let(:request) do
    double(headers: {}, params: {})
  end

  it "uses subset when cart_token and items are both present" do
    params = {
      cart_token: cart.guest_token,
      items: [{ sku: "CTX-A", quantity: 1 }]
    }
    resolved = described_class.resolve(params: params, request: request)
    expect(resolved.cart_items.size).to eq(1)
    expect(resolved.cart_items.first.product_sku).to eq("CTX-A")
    expect(resolved.cart_items.first.quantity).to eq(1)
  end

  it "resolves draft order by order_id for owner" do
    order = create(:order, user: user, checkout_draft: true)
    create(:order_item, order: order, product_sku: "CTX-A", quantity: 1, price: 10.0)

    params = { order_id: order.id }
    resolved = described_class.resolve(params: params, request: request, user: user)
    expect(resolved.cart_items.map(&:product_sku)).to eq(["CTX-A"])
  end
end
