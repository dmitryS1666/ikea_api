require "rails_helper"

RSpec.describe "Account purchases API", type: :request do
  let(:date) { Date.current }
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  before do
    CalculatorSetting.initialize_defaults

    ExchangeRate.create!(
      date: date,
      currency_code: "PLN",
      rate: 0.85,
      official_rate: 0.85,
      scale: 1
    )
  end

  let(:product) do
    create(
      :product,
      sku: "s00571245",
      name: "FÖNSTERBLAD",
      small_desc_name: "Рулонная штора, бежевый, 100x155 см",
      local_images: ["/images/products/example.jpg"]
    ).tap { |record| record.update_column(:cached_slug, "fonsterblad-rulonnaya-shtora-00571245") }
  end
  let!(:order) do
    create(
      :order,
      user: user,
      status: :completed,
      purchased_at: Time.zone.parse("2026-06-15T10:00:00Z")
    )
  end
  let!(:order_item) do
    create(
      :order_item,
      order: order,
      product: product,
      product_sku: product.sku,
      quantity: 1,
      price: 81.53
    )
  end

  it "returns purchase items with catalog-style product payload" do
    get "/api/v1/account/purchases", headers: headers

    expect(response).to have_http_status(:ok)

    body = JSON.parse(response.body)
    purchase = body.fetch("purchases").first

    expect(purchase).to include(
      "id" => order_item.id,
      "order_id" => order.id,
      "product_sku" => "00571245",
      "sku" => "00571245",
      "quantity" => 1,
      "price_byn" => "81.53",
      "unit_price_byn" => "81.53",
      "total_price_byn" => "81.53",
      "purchased_at" => order.purchased_at.iso8601
    )

    expect(purchase["product"]).to include(
      "sku" => "00571245",
      "slug" => "fonsterblad-rulonnaya-shtora-00571245",
      "name_ru" => "FÖNSTERBLAD",
      "small_desc_name" => "Рулонная штора, бежевый, 100x155 см"
    )
    expect(purchase.dig("product", "local_images")).to be_an(Array)
    expect(purchase.dig("product", "variants")).to be_an(Array)
  end

  it "excludes non-purchased orders" do
    create(:order, user: user, status: :processing)

    get "/api/v1/account/purchases", headers: headers

    expect(JSON.parse(response.body).fetch("purchases").size).to eq(1)
  end

  it "requires authentication" do
    get "/api/v1/account/purchases"

    expect(response).to have_http_status(:unauthorized)
  end
end
