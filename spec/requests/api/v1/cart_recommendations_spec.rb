# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cart recommendations API", type: :request do
  let!(:product_a) { create(:product, sku: "11111111", name: "Cart Rec A", quantity: 5, price: 49.9) }
  let!(:product_b) { create(:product, sku: "22222222", name: "Cart Rec B", quantity: 5, price: 59.9) }
  let!(:product_c) { create(:product, sku: "33333333", name: "Cart Rec C", quantity: 5, price: 69.9) }

  before do
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CalculatorSetting).to receive(:get).and_return(nil)

    setting = ProductRecommendationSetting.cart.first_or_initialize
    setting.assign_attributes(
      source_type: :sku_list,
      active: true,
      product_skus: %w[11111111 22222222 33333333],
      category_id: nil
    )
    setting.save!
  end

  it "returns active cart recommendation products with meta.placement=cart" do
    get "/api/v1/cart/recommendations"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body.dig("meta", "placement")).to eq("cart")
    expect(body.dig("meta", "total")).to eq(3)
    expect(body["data"]).to be_an(Array)
    expect(body["data"].size).to eq(3)
    expect(body["data"].map { |row| row.dig("attributes", "name") }).to eq(
      ["Cart Rec A", "Cart Rec B", "Cart Rec C"]
    )
  end

  it "respects per_page and exclude_skus" do
    get "/api/v1/cart/recommendations", params: { per_page: 2, exclude_skus: ["11111111"] }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body.dig("meta", "placement")).to eq("cart")
    expect(body.dig("meta", "total")).to eq(2)
    expect(body["data"].map { |row| row.dig("attributes", "name") }).to eq(
      ["Cart Rec B", "Cart Rec C"]
    )
  end

  it "returns empty data when cart setting is inactive" do
    ProductRecommendationSetting.cart.update_all(active: false)

    get "/api/v1/cart/recommendations"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body.dig("meta", "placement")).to eq("cart")
    expect(body.dig("meta", "total")).to eq(0)
    expect(body["data"]).to eq([])
  end
end
