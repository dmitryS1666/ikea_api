require "rails_helper"

RSpec.describe "Checkout multi-step (draft) flow", type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-DRAFT-CHK",
      quantity: 10,
      price: 100.0,
      weight: 10.0,
      package_volume: 0.02,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end

  before do
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
    allow(EuropostApiService).to receive(:offices_out).and_return(
      [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
    )
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(WebpayPaymentLinkService).to receive(:issue_link!).and_call_original
    allow(OrderNotificationService).to receive(:call)
    allow(TelegramService).to receive(:send_message)
  end

  it "creates draft, updates delivery, finalizes with Webpay link and clears checkout_draft" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    order = Order.last
    expect(order.checkout_draft).to be true
    expect(user.reload.cart.cart_items).to be_empty

    patch "/api/v1/checkout/#{order.id}", params: {
      delivery_type: "europost_pickup",
      pickup_point_id: "70130010",
      full_name: "User",
      phone: "375291112233",
      payment_method: "card"
    }, headers: headers
    expect(response).to have_http_status(:ok)

    post "/api/v1/checkout/#{order.id}/finalize", params: {
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    }, headers: headers

    expect(response).to have_http_status(:created)
    order.reload
    expect(order.checkout_draft).to be false
    expect(order.payment_url).to be_present
    expect(WebpayPaymentLinkService).to have_received(:issue_link!).once
  end

  it "returns 409 when legacy checkout is attempted while draft exists" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)

    post "/api/v1/checkout", params: {
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    }, headers: headers

    expect(response).to have_http_status(:conflict)
    json = JSON.parse(response.body)
    expect(json["code"]).to eq("checkout_draft_exists")
  end

  it "replaces old draft and creates a new one when posting draft twice" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    first_id = Order.last.id

    user.create_cart if user.cart.nil?
    create(:cart_item, cart: user.cart, product_sku: product.sku, quantity: 2)
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    json = JSON.parse(response.body)
    expect(json["order_id"]).not_to eq(first_id)
    expect(json["message"]).to eq("Черновик заказа создан")
    expect(Order.where(id: first_id)).to be_empty
    expect(Order.find(json["order_id"]).checkout_draft).to be true
  end
end
