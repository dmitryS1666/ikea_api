require "rails_helper"

RSpec.describe "Checkout multi-step (draft) flow", type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-DRAFT-#{SecureRandom.hex(4)}",
      quantity: 10,
      price: 100.0,
      weight: 10.0,
      package_volume: 0.02,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "10 кг", "count" => 1, "width" => "20 см", "height" => "30 см", "length" => "40 см" }
            ]
          }
        }
      }
    )
  end

  before do
    user.orders.where(checkout_draft: true).find_each do |draft|
      CheckoutService.cancel_draft(user: user, order_id: draft.id)
    end
    cart.cart_items.destroy_all
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
    allow(EuropostApiService).to receive(:offices_out).and_return(
      [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
    )
    allow(EuropostOfficeHoursEnricher).to receive(:enrich) do |offices, **_kwargs|
      offices
    end
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(WebpayPaymentLinkService).to receive(:issue_link!).and_call_original
    allow(OrderNotificationService).to receive(:call)
    allow(TelegramService).to receive(:send_message)
  end

  it "creates draft, updates delivery, finalizes with Webpay link and clears checkout_draft" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    order = Order.last
    expect(order.checkout_draft).to be true
    expect(user.reload.cart.cart_items).not_to be_empty
    expect(body["pricing"]).to be_present
    expect(body.dig("pricing", "items", 0, "pricing", "unit_price_new_byn")).to be_present
    totals = body["pricing"]["totals"]
    expect(totals["subtotal_new_byn"]).to be_present
    expect(totals["delivery_to_belarus_byn"]).to be_present
    if totals["delivery_to_belarus_byn"].to_f.positive?
      expect(totals["subtotal_new_byn"].to_f + totals["delivery_to_belarus_byn"].to_f).to be_within(0.02).of(
        totals["total_byn"].to_f + totals["discount_total_byn"].to_f
      )
    end

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
    expect(order.status).to eq("processing")
    expect(order.payment_url).to be_present
    expect(WebpayPaymentLinkService).to have_received(:issue_link!).once
    expect(user.reload.cart.cart_items).to be_empty
  end

  it "returns delivery options based on draft order VGH" do
    allow(Delivery::ParcelPackingService).to receive(:call).and_return(
      total_weight_kg: 120.0,
      total_volume_m3: 3.375,
      max_dimension_cm: 150.0,
      max_dimensions_sum_cm: 450.0,
      parcels_count: 1,
      parcels: [
        { sku: product.sku, weight_kg: 120.0, width_cm: 150.0, height_cm: 150.0, depth_cm: 150.0, volume_m3: 3.375, eligible_for_europost: false, ineligible_reason: "max_weight_exceeded" }
      ],
      eligible_for_europost: false,
      ineligible_reason: "max_weight_exceeded"
    )

    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)

    body = JSON.parse(response.body)
    expect(body["delivery_options"]).to be_present
    methods = body.dig("delivery_options", "methods") || []
    europost = methods.find { |m| m["code"] == "europost_pickup" }
    expect(europost).to be_present
    expect(europost["available"]).to eq(false)
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

  it "replaces draft when posting draft with different selection while draft exists" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    first_id = Order.last.id

    other = create(:product, sku: "SKU-DRAFT-OTHER", quantity: 10, price: 50.0, weight: 5.0,
                             package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm",
                             dimensions: "20 x 30 x 40 cm", full_attributes: {})
    create(:cart_item, cart: cart, product_sku: other.sku, quantity: 1)
    post "/api/v1/checkout", params: { draft: true, items: [{ sku: other.sku, quantity: 1 }] }, headers: headers
    expect(response).to have_http_status(:created)
    json = JSON.parse(response.body)
    second_id = json["order_id"]
    expect(second_id).not_to eq(first_id)

    expect(Order.find(first_id).checkout_draft).to be false
    expect(Order.find(first_id).status).to eq("cancelled")
    expect(Order.find(second_id).checkout_draft).to be true
    expect(Order.find(second_id).order_items.pluck(:product_sku, :quantity)).to eq([[other.sku, 1]])
  end

  it "returns 200 with same order when posting draft twice with same selection" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    first_id = JSON.parse(response.body)["order_id"]

    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["order_id"]).to eq(first_id)
  end

  it "updates draft with courier delivery_type without address and recalculates delivery" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    order_id = JSON.parse(response.body)["order_id"]

    allow(EuropostPostalPaymentQuote).to receive(:call).and_return(
      success: true,
      postal_total_byn: 9.5,
      currency: "BYN",
      payload: { "delivery_type" => 2 },
      raw: { "sender_pays" => 9.5 }
    )

    patch "/api/v1/checkout/#{order_id}", params: {
      delivery_type: "courier",
      payment_method: "card"
    }, headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    order = Order.find(order_id)
    expect(order.delivery_type).to eq("courier")
    expect(order.delivery_price.to_f).to be > 0
    expect(body.dig("pricing", "delivery", "type")).to eq("courier")
    expect(body.dig("pricing", "delivery", "title")).to eq("Курьерская доставка")
    expect(body.dig("pricing", "totals", "delivery_total_byn")).to eq(format("%.2f", order.delivery_price))
  end

  it "loads draft via GET /checkout/:id" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    order_id = JSON.parse(response.body)["order_id"]

    get "/api/v1/checkout/#{order_id}", headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "attributes", "checkout_draft")).to eq(true)
  end

  it "loads draft via GET /checkout/draft fallback" do
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    order_id = JSON.parse(response.body)["order_id"]

    get "/api/v1/checkout/draft", params: { draft_id: order_id }, headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "attributes", "checkout_draft")).to eq(true)
  end

  it "creates draft from explicit cart_token selected items and returns stable draft ids" do
    guest_cart = create(:cart, user: nil, guest_token: 'guest-draft-token')
    other = create(:product, sku: "SKU-DRAFT-TOKEN", quantity: 10, price: 180.0, weight: 5.0,
                             package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm",
                             dimensions: "20 x 30 x 40 cm", full_attributes: {})
    create(:cart_item, cart: guest_cart, product_sku: other.sku, quantity: 2)

    post "/api/v1/checkout",
         params: { draft: true, cart_token: guest_cart.guest_token, items: [{ sku: other.sku, quantity: 1 }] },
         headers: headers

    expect(response).to have_http_status(:created)
    json = JSON.parse(response.body)
    expect(json["order_id"]).to be_present
    expect(json["draft_id"]).to eq(json["order_id"])
    expect(json["draft_order_id"]).to eq(json["order_id"])
    expect(json["id"]).to eq(json["order_id"])

    order = Order.find(json["order_id"])
    expect(order.checkout_draft).to be true
    expect(order.order_items.pluck(:product_sku, :quantity)).to eq([[other.sku, 1]])
  end

  it "returns cart_empty for draft checkout with empty selected items" do
    post "/api/v1/checkout", params: { draft: true, items: [] }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["code"]).to eq("cart_empty")
  end

  it "returns item_not_in_cart for draft checkout with missing selected SKU" do
    post "/api/v1/checkout", params: { draft: true, items: [{ sku: 'MISSING', quantity: 1 }] }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    json = JSON.parse(response.body)
    expect(json["code"]).to eq("item_not_in_cart")
    expect(json["sku"]).to eq("MISSING")
  end

end
