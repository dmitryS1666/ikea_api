require "rails_helper"

RSpec.describe CartSummaryService do
  let(:user) { create(:user) }
  let(:cart) { create(:cart, user: user) }
  let!(:product_a) do
    create(
      :product,
      sku: "SKU-SUM-A",
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
      sku: "SKU-SUM-B",
      quantity: 10,
      price: 200.0,
      weight: 8.0,
      package_volume: 0.03,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end
  let(:selections) do
    [CartSelectionService::ItemSelection.new(sku: product_a.sku, quantity: 1)]
  end

  before do
    create(:cart_item, cart: cart, product_sku: product_a.sku, quantity: 2)
    create(:cart_item, cart: cart, product_sku: product_b.sku, quantity: 1)
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
  end

  it "returns totals only for selected items" do
    summary = described_class.call(cart: cart, items: selections)
    full = CartPricingService.call(cart: cart)

    expect(summary[:items_count]).to eq(1)
    expect(summary[:total_byn].to_f).to be < full[:totals][:total_byn].to_f
    expect(summary[:delivery]).to include(:available_methods, :europost_eligible)
  end
end
