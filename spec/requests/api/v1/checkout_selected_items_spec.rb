require "rails_helper"

RSpec.describe "Checkout with selected cart items", type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:cart) { create(:cart, user: user) }
  let!(:product_a) do
    create(
      :product,
      sku: "SKU-SEL-A",
      quantity: 10,
      price: 100.0,
      weight: 5.0,
      package_volume: 0.02,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end
  let!(:product_b) do
    create(
      :product,
      sku: "SKU-SEL-B",
      quantity: 10,
      price: 200.0,
      weight: 8.0,
      package_volume: 0.03,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end

  before do
    create(:cart_item, cart: cart, product_sku: product_a.sku, quantity: 2)
    create(:cart_item, cart: cart, product_sku: product_b.sku, quantity: 1)
    allow(EuropostApiService).to receive(:offices_out).and_return(
      [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
    )
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(WebpayPaymentLinkService).to receive(:issue_link!).and_call_original
    allow(OrderNotificationService).to receive(:call)
    allow(TelegramService).to receive(:send_message)
  end

  it "creates draft with only selected items and keeps the rest in cart" do
    post "/api/v1/checkout",
         params: {
           draft: true,
           items: [{ sku: product_a.sku, quantity: 1 }]
         },
         headers: headers

    expect(response).to have_http_status(:created)
    order = Order.last
    expect(order.order_items.pluck(:product_sku, :quantity)).to eq([[product_a.sku, 1]])
    expect(user.cart.cart_items.find_by(product_sku: product_a.sku).quantity).to eq(1)
    expect(user.cart.cart_items.find_by(product_sku: product_b.sku).quantity).to eq(1)
  end

  it "finalizes draft when items match order lines" do
    post "/api/v1/checkout",
         params: {
           draft: true,
           items: [{ sku: product_a.sku, quantity: 1 }]
         },
         headers: headers
    order = Order.last

    patch "/api/v1/checkout/#{order.id}",
          params: {
            delivery_type: "europost_pickup",
            pickup_point_id: "70130010",
            full_name: "User",
            phone: "375291112233",
            payment_method: "card"
          },
          headers: headers
    expect(response).to have_http_status(:ok)

    post "/api/v1/checkout/#{order.id}/finalize",
         params: {
           full_name: "User",
           phone: "375291112233",
           delivery_type: "europost_pickup",
           payment_method: "card",
           pickup_point_id: "70130010",
           items: [{ sku: product_a.sku, quantity: 1 }]
         },
         headers: headers

    expect(response).to have_http_status(:created)
    expect(order.reload.order_items.sum(:quantity)).to eq(1)
  end
end
