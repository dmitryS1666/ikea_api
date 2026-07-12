# frozen_string_literal: true

require "rails_helper"
require "uri"

RSpec.describe "Signed order reorder link", type: :request do
  let(:user) { create(:user) }
  let(:order) { create(:order, user: user, status: :cancelled, checkout_draft: false) }
  let!(:product) { create(:product, sku: "REORDER-SKU", quantity: 5) }

  before do
    create(:order_item, order: order, product_sku: product.sku, quantity: 2, price: 25.0)
  end

  it "updates the cart once and redirects the email click to the cart" do
    path = URI.parse(OrderReorderLinkService.url_for(order)).request_uri

    get path

    expect(response).to redirect_to("https://ikeya.by/cart?reorder=updated")
    expect(user.reload.cart.cart_items.find_by!(product_sku: product.sku).quantity).to eq(2)

    get path
    expect(user.reload.cart.cart_items.find_by!(product_sku: product.sku).quantity).to eq(2)
  end


  it "rejects the link if the order is no longer cancelled" do
    path = URI.parse(OrderReorderLinkService.url_for(order)).request_uri
    order.update_column(:status, Order.statuses[:processing])

    get path

    expect(response).to redirect_to("https://ikeya.by/cart?reorder=invalid")
    expect(user.reload.cart).to be_nil
  end

  it "rejects a forged token without changing the cart" do
    get "/api/v1/order_reorders/forged"

    expect(response).to redirect_to("https://ikeya.by/cart?reorder=invalid")
    expect(user.reload.cart).to be_nil
  end
end
