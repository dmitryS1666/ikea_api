# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cart Belarus delivery for selected items", type: :request do
  let(:user) { create(:user) }
  let(:headers) { { "Authorization" => "Bearer #{JwtService.encode(user_id: user.id)}" } }
  let!(:cart) { create(:cart, user: user) }

  let!(:light_a) { create(:product, sku: "SEL-LIGHT-A", quantity: 10, price: 30.0, weight: 0.5, delivery_cost: 5.0) }
  let!(:light_b) { create(:product, sku: "SEL-LIGHT-B", quantity: 10, price: 35.0, weight: 0.8, delivery_cost: 5.0) }
  let!(:light_c) { create(:product, sku: "SEL-LIGHT-C", quantity: 10, price: 20.0, weight: 0.4, delivery_cost: 5.0) }
  let!(:heavy_desk) do
    create(
      :product,
      sku: "SEL-HEAVY-DESK",
      quantity: 20,
      price: 248.0,
      weight: 26.72,
      delivery_cost: 5.0,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "26.72 кг", "count" => 1, "width" => "74 см", "height" => "11 см", "length" => "111 см" }
            ]
          }
        }
      }
    )
  end

  let(:selected_items) do
    [
      { sku: light_a.sku, quantity: 1 },
      { sku: light_b.sku, quantity: 1 },
      { sku: light_c.sku, quantity: 1 }
    ]
  end

  before do
    CalculatorSetting.initialize_defaults
    ExchangeRate.create!(date: Date.today, currency_code: "PLN", rate: 0.85, official_rate: 0.85, scale: 1)
    ExchangeRate.create!(date: Date.today, currency_code: "EUR", rate: 3.5, official_rate: 3.5, scale: 1)

    create(:cart_item, cart: cart, product_sku: light_a.sku, quantity: 1)
    create(:cart_item, cart: cart, product_sku: light_b.sku, quantity: 1)
    create(:cart_item, cart: cart, product_sku: light_c.sku, quantity: 1)
    create(:cart_item, cart: cart, product_sku: heavy_desk.sku, quantity: 10)
  end

  def full_cart_totals
    get "/api/v1/cart", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).dig("cart", "totals")
  end

  def summary_totals(items = selected_items)
    post "/api/v1/cart/summary", params: { items: items }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def cart_totals_with_items(items = selected_items)
    get "/api/v1/cart", params: { items: items }, headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).dig("cart", "totals")
  end

  it "recalculates Belarus delivery when heavy item is excluded from selection" do
    full = full_cart_totals
    partial = summary_totals

    expect(full["total_weight_kg"].to_f).to be > 200.0
    expect(partial["total_weight_kg"].to_f).to be < 10.0
    expect(partial["delivery_to_belarus_byn"].to_f).to be < full["delivery_to_belarus_byn"].to_f / 2.0
    expect(partial["subtotal_new_byn"].to_f).to be < full["subtotal_new_byn"].to_f / 2.0

    visible_total = partial["subtotal_new_byn"].to_f +
                    partial["delivery_to_belarus_byn"].to_f -
                    partial["discount_total_byn"].to_f
    expect(visible_total.round(2)).to eq(partial["total_byn"].to_f)
  end

  it "mirrors selected totals under cart.totals for sidebar consumers" do
    partial = summary_totals

    expect(partial.dig("cart", "totals", "delivery_to_belarus_byn")).to eq(partial["delivery_to_belarus_byn"])
    expect(partial.dig("cart", "totals", "subtotal_new_byn")).to eq(partial["subtotal_new_byn"])
    expect(partial.dig("cart", "totals", "total_weight_kg").to_f).to eq(partial["total_weight_kg"].to_f)
    expect(partial.dig("cart", "delivery", "delivery_to_belarus_byn")).to eq(partial["delivery_to_belarus_byn"])
    expect(partial.dig("cart", "items_count")).to eq(partial["items_count"])
  end

  it "returns the same Belarus delivery from GET /cart with items query as POST /cart/summary" do
    summary = summary_totals
    cart_subset = cart_totals_with_items

    expect(cart_subset["delivery_to_belarus_byn"]).to eq(summary["delivery_to_belarus_byn"])
    expect(cart_subset["total_weight_kg"].to_f).to eq(summary["total_weight_kg"].to_f)
    expect(cart_subset["subtotal_new_byn"]).to eq(summary["subtotal_new_byn"])
  end
end
