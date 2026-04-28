require "rails_helper"

RSpec.describe "Delivery calculate types", type: :request do
  let!(:pickup_point) do
    create(
      :pickup_point,
      provider: "europost",
      active: true,
      max_weight_kg: 200.0,
      max_volume_m3: 5.0
    )
  end

  let!(:cart) { create(:cart) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-DEL-1",
      quantity: 10,
      price: 100.0,
      weight: 10.0,
      package_volume: 0.03,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end

  before do
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 2)
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(PriceCalculationService).to receive(:exchange_rate_buffer).and_return(1.0)
  end

  def calculate(delivery_type:)
    post "/api/v1/delivery/calculate", params: { cart_token: cart.guest_token, delivery_type: delivery_type }
  end

  it "returns payload for europost_pickup" do
    calculate(delivery_type: "europost_pickup")

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to include("basis", "delivery", "pickup_point")
    expect(body["delivery"]["normalized_delivery_type"]).to eq("europost_pickup")
    expect(body["delivery"]["available"]).to be(true)
    expect(body["delivery"]["delivery_price_byn"]).to be_present
    expect(body["delivery"]["delivery_to_belarus_price_byn"]).to be_present
    expect(body["delivery"]["total_delivery_price_byn"]).to be_present
    expect(body["delivery"]["delivery_date"]).to be_present
    expect(body["delivery"]).to have_key("storage_until")
    expect(body["delivery"]["display"]).to be_a(Hash)
  end

  it "returns payload for courier" do
    calculate(delivery_type: "courier")

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["delivery"]["normalized_delivery_type"]).to eq("courier")
    expect(body["delivery"]["available"]).to be(true)
    expect(body["delivery"]["delivery_price_byn"].to_f).to be > 0
    expect(body["delivery"]["total_delivery_price_byn"].to_f).to be > 0
  end

  it "returns payload for ikeya_delivery when europost is ineligible" do
    product.update!(weight: nil, package_volume: nil, package_dimensions: nil, dimensions: nil)
    calculate(delivery_type: "ikeya_delivery")

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["delivery"]["normalized_delivery_type"]).to eq("ikeya_delivery")
    expect(body["delivery"]["delivery_price_byn"]).to eq("0.00")
    expect(body["delivery"]["total_delivery_price_byn"].to_f).to eq(body["delivery"]["delivery_to_belarus_price_byn"].to_f)
  end

  it "normalizes legacy pickup to europost_pickup" do
    calculate(delivery_type: "pickup")

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["delivery"]["delivery_type"]).to eq("pickup")
    expect(body["delivery"]["normalized_delivery_type"]).to eq("europost_pickup")
  end

  it "returns 422 for unavailable type by VGH" do
    product.update!(weight: nil, package_volume: nil, package_dimensions: nil, dimensions: nil)
    calculate(delivery_type: "courier")

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["error"]).to be_present
    expect(body["normalized_delivery_type"]).to eq("courier")
    expect(body["reason"]).to be_present
  end
end
