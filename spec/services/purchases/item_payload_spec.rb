require "rails_helper"

RSpec.describe Purchases::ProductCardPayload do
  let(:date) { Date.current }

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

  it "returns catalog-style product fields for purchase cards" do
    payload = described_class.call(product)

    expect(payload).to include(
      sku: "00571245",
      slug: "fonsterblad-rulonnaya-shtora-00571245",
      name: "FÖNSTERBLAD",
      name_ru: "FÖNSTERBLAD",
      translated_name: "FÖNSTERBLAD",
      small_desc_name: "Рулонная штора, бежевый, 100x155 см"
    )
    expect(payload[:local_images]).to be_an(Array)
    expect(payload[:variants]).to be_an(Array)
    expect(payload[:price_byn]).to be_present
  end

  it "returns nil when product is missing" do
    expect(described_class.call(nil)).to be_nil
  end
end

RSpec.describe Purchases::ItemPayload do
  let(:date) { Date.current }
  let(:user) { create(:user) }

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
      small_desc_name: "Рулонная штора, бежевый, 100x155 см"
    ).tap { |record| record.update_column(:cached_slug, "fonsterblad-rulonnaya-shtora-00571245") }
  end
  let(:order) do
    create(
      :order,
      user: user,
      status: :completed,
      purchased_at: Time.zone.parse("2026-06-15T10:00:00Z")
    )
  end
  let(:order_item) do
    create(
      :order_item,
      order: order,
      product: product,
      product_sku: product.sku,
      quantity: 2,
      price: 81.53
    )
  end

  it "builds purchase item payload with unit purchase price and product card data" do
    payload = described_class.call(order_item: order_item, order: order, product: product)

    expect(payload).to include(
      id: order_item.id,
      order_id: order.id,
      product_sku: "00571245",
      sku: "00571245",
      quantity: 2,
      price_byn: "81.53",
      unit_price_byn: "81.53",
      total_price_byn: "163.06",
      purchased_at: order.purchased_at.iso8601
    )
    expect(payload[:product]).to include(
      sku: "00571245",
      slug: "fonsterblad-rulonnaya-shtora-00571245",
      name_ru: "FÖNSTERBLAD",
      small_desc_name: "Рулонная штора, бежевый, 100x155 см"
    )
  end
end
