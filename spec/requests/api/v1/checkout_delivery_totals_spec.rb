# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Checkout delivery totals contract", type: :request do
  include CheckoutDeliveryTotalsHelpers

  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-TOTALS-#{SecureRandom.hex(4)}",
      quantity: 10,
      price: 100.0,
      weight: 10.0,
      delivery_cost: 12.0,
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
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 4)
    allow(EuropostApiService).to receive(:offices_out).and_return(
      [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
    )
    allow(EuropostOfficeHoursEnricher).to receive(:enrich) { |offices, **_kwargs| offices }
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
  end

  def create_draft!
    post "/api/v1/checkout", params: { draft: true }, headers: headers
    expect(response).to have_http_status(:created)
    JSON.parse(response.body)
  end

  describe "cart stage" do
    it "returns cart totals where Belarus delivery is included in total_byn" do
      get "/api/v1/cart", headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      totals = body.dig("cart", "totals")
      expect_cart_stage_totals_contract!(totals)
    end

    it "returns the same contract in cart summary for selected items" do
      post "/api/v1/cart/summary",
           params: { items: [{ sku: product.sku, quantity: 2 }] },
           headers: headers
      expect(response).to have_http_status(:ok)

      totals = JSON.parse(response.body)
      expect_cart_stage_totals_contract!(totals)
    end
  end

  describe "checkout draft without selected delivery method" do
    it "includes Belarus delivery in total_byn and exposes zero delivery_method_byn" do
      body = create_draft!
      totals = body.dig("pricing", "totals")
      order = Order.find(body["order_id"])

      expect(totals["delivery_method_byn"]).to eq("0.00")
      expect_cart_stage_totals_contract!(totals)
      expect_order_amounts_match_pricing!(order: order, totals: totals, order_payload: body["order"])
    end

    it "keeps total_weight_kg aligned with cart parcel packing for the same selection" do
      get "/api/v1/cart", headers: headers
      expect(response).to have_http_status(:ok)
      cart_totals = JSON.parse(response.body).dig("cart", "totals")

      body = create_draft!
      checkout_totals = body.dig("pricing", "totals")

      expect(checkout_totals["total_weight_kg"].to_f).to eq(cart_totals["total_weight_kg"].to_f)
      expect(checkout_totals["subtotal_new_byn"]).to eq(cart_totals["subtotal_new_byn"])
    end
  end

  describe "regression: production totals bug" do
    it "documents the additive contract with the reported numbers" do
      totals = {
        "subtotal_new_byn" => "185.72",
        "discount_total_byn" => "0.00",
        "delivery_to_belarus_byn" => "6.01",
        "delivery_method_byn" => "12.43",
        "delivery_total_byn" => "18.44",
        "total_byn" => "204.16"
      }

      expect_checkout_delivery_totals_contract!(totals)
      expect(totals["total_byn"].to_f).not_to eq(198.15)
      expect(totals["total_byn"].to_f).not_to eq(204.22)
    end
  end

  describe "checkout draft with europost pickup" do
    before do
      allow(CheckoutService).to receive(:delivery_prices_for).and_return(
        delivery_price_byn: 12.43,
        delivery_to_belarus_price_byn: 1.0,
        total_delivery_price_byn: 13.43
      )
    end

    it "adds pickup fee on top of Belarus delivery in total_byn" do
      initial = create_draft!
      cart_belarus = initial.dig("pricing", "totals", "delivery_to_belarus_byn").to_f
      cart_total = initial.dig("pricing", "totals", "total_byn").to_f
      order_id = initial["order_id"]

      patch "/api/v1/checkout/#{order_id}",
            params: { delivery_type: "europost_pickup", pickup_point_id: "70130010", payment_method: "card" },
            headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      totals = body.dig("pricing", "totals")
      delivery = body.dig("pricing", "delivery")
      order = Order.find(order_id)

      expect(totals["delivery_to_belarus_byn"].to_f).to eq(cart_belarus)
      expect(totals["delivery_method_byn"]).to eq("12.43")
      expect_checkout_delivery_totals_contract!(totals, delivery: delivery)
      expect(totals["total_byn"].to_f).to be_within(0.02).of(cart_total + 12.43)
      expect_order_amounts_match_pricing!(order: order, totals: totals, order_payload: body.dig("data", "attributes") || body["order"])
    end
  end

  describe "checkout draft with courier" do
    before do
      allow(EuropostPostalPaymentQuote).to receive(:call).and_return(
        success: true,
        postal_total_byn: 18.5,
        currency: "BYN",
        payload: { "delivery_type" => 2 },
        raw: { "sender_pays" => 18.5 }
      )
    end

    it "adds courier fee on top of Belarus delivery in total_byn" do
      initial = create_draft!
      cart_belarus = initial.dig("pricing", "totals", "delivery_to_belarus_byn").to_f
      cart_total = initial.dig("pricing", "totals", "total_byn").to_f
      order_id = initial["order_id"]

      patch "/api/v1/checkout/#{order_id}",
            params: { delivery_type: "courier", payment_method: "card" },
            headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      totals = body.dig("pricing", "totals")
      delivery = body.dig("pricing", "delivery")
      order = Order.find(order_id)

      expect(totals["delivery_to_belarus_byn"].to_f).to eq(cart_belarus)
      expect(totals["delivery_method_byn"]).to eq("18.50")
      expect_checkout_delivery_totals_contract!(totals, delivery: delivery)
      expect(totals["total_byn"].to_f).to be_within(0.02).of(cart_total + 18.5)
      expect_order_amounts_match_pricing!(order: order, totals: totals)
    end
  end

  describe "draft refresh after delivery was selected" do
    before do
      allow(CheckoutService).to receive(:delivery_prices_for).and_return(
        delivery_price_byn: 18.5,
        delivery_to_belarus_price_byn: 1.0,
        total_delivery_price_byn: 19.5
      )
    end

    it "resets totals to cart-only when draft is reused without delivery_type" do
      initial = create_draft!
      order_id = initial["order_id"]
      cart_total = initial.dig("pricing", "totals", "total_byn").to_f

      patch "/api/v1/checkout/#{order_id}",
            params: { delivery_type: "courier", payment_method: "card" },
            headers: headers
      expect(response).to have_http_status(:ok)

      other = create(
        :product,
        sku: "SKU-TOTALS-OTHER-#{SecureRandom.hex(3)}",
        quantity: 10,
        price: 50.0,
        weight: 5.0,
        package_volume: 0.02,
        package_dimensions: "20 x 30 x 40 cm",
        dimensions: "20 x 30 x 40 cm",
        full_attributes: {}
      )
      create(:cart_item, cart: cart, product_sku: other.sku, quantity: 1)

      post "/api/v1/checkout",
           params: { draft: true, items: [{ sku: other.sku, quantity: 1 }] },
           headers: headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      totals = body.dig("pricing", "totals")
      order = Order.find(order_id)

      expect(order.delivery_type).to be_nil
      expect_cart_stage_totals_contract!(totals)
      expect(totals["total_byn"].to_f).not_to be_within(0.02).of(cart_total + 18.5)
      expect_order_amounts_match_pricing!(order: order, totals: totals, order_payload: body["order"])
    end
  end

  describe "delivery calculate endpoint" do
    let(:guest_cart) do
      c = create(:cart, user: nil, guest_token: "guest-totals-token")
      create(:cart_item, cart: c, product_sku: product.sku, quantity: 4)
      c
    end

    it "includes Belarus delivery in totals.total_byn for europost pickup" do
      allow(EuropostPostalPaymentQuote).to receive(:call).and_return(
        success: true,
        postal_total_byn: 12.43,
        currency: "BYN",
        payload: {},
        raw: {}
      )

      post "/api/v1/delivery/calculate",
           params: { cart_token: guest_cart.guest_token, delivery_type: "europost_pickup", pickup_point_id: "70130010" }
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      totals = body["totals"]
      delivery = body["delivery"]

      expect_checkout_delivery_totals_contract!(totals, delivery: delivery)
      expect(body["total_byn"]).to eq(totals["total_byn"])
      expect(delivery["display"]["total_byn"]).to eq(totals["total_byn"])
    end

    it "includes Belarus delivery in totals.total_byn for courier" do
      allow(EuropostPostalPaymentQuote).to receive(:call).and_return(
        success: true,
        postal_total_byn: 18.5,
        currency: "BYN",
        payload: {},
        raw: {}
      )

      post "/api/v1/delivery/calculate",
           params: {
             cart_token: guest_cart.guest_token,
             delivery_type: "courier",
             address: { city: "Минск", street: "Ленина", house: "10" }
           }
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect_checkout_delivery_totals_contract!(body["totals"], delivery: body["delivery"])
    end
  end
end
