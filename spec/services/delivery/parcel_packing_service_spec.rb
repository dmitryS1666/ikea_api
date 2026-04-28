require "rails_helper"

RSpec.describe Delivery::ParcelPackingService do
  let(:cart) { create(:cart) }

  def add_item(product, quantity:)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: quantity)
  end

  before do
    allow(CalculatorSetting).to receive(:get).and_call_original
    allow(CalculatorSetting).to receive(:get).with("europost_max_weight_kg").and_return(30.0)
    allow(CalculatorSetting).to receive(:get).with("europost_max_volume_m3").and_return(0.25)
    allow(CalculatorSetting).to receive(:get).with("europost_max_dimension_cm").and_return(120.0)
    allow(CalculatorSetting).to receive(:get).with("europost_max_side_dimensions_cm").and_return(nil)
  end

  it "one product passes" do
    product = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:parcels].size).to eq(1)
    expect(result[:parcels].first[:eligible_for_europost]).to be(true)
  end

  it "one product fails by weight" do
    product = create(:product, weight: 35, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("max_weight_exceeded")
  end

  it "one product fails by volume" do
    product = create(:product, weight: 5, package_volume: 0.4, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("max_volume_exceeded")
  end

  it "one product fails by max dimension" do
    product = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 140 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("max_dimension_exceeded")
  end

  it "quantity greater than one creates multiple parcels" do
    product = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 3)

    result = described_class.call(cart)

    expect(result[:parcels].size).to eq(3)
    expect(result[:total_weight_kg]).to eq(15.0)
  end

  it "fails when product has no weight" do
    product = create(:product, weight: nil, net_weight: nil, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("missing_weight")
  end

  it "fails when product has no dimensions" do
    product = create(:product, weight: 5, package_volume: 0.02, package_dimensions: nil, dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("missing_dimensions")
  end

  it "mixed cart with one invalid parcel marks whole order ineligible" do
    valid = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    invalid = create(:product, weight: 35, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(valid, quantity: 1)
    add_item(invalid, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:parcels].map { |p| p[:eligible_for_europost] }).to include(false)
  end

  it "all products valid marks whole order eligible" do
    p1 = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    p2 = create(:product, weight: 3, package_volume: 0.01, package_dimensions: "10 x 20 x 30 cm", dimensions: nil, full_attributes: {})
    add_item(p1, quantity: 1)
    add_item(p2, quantity: 2)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:parcels].all? { |p| p[:eligible_for_europost] }).to be(true)
  end
end
