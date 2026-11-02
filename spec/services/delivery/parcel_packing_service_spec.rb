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
    allow(CalculatorSetting).to receive(:get).with("europost_max_dimension_cm").and_return(105.0)
    allow(CalculatorSetting).to receive(:get).with("europost_max_dimensions_sum_cm").and_return(180.0)
    allow(CalculatorSetting).to receive(:get).with("europost_max_side_dimensions_cm").and_return(nil)
    # Product has after_commit hooks that enqueue filter reindex jobs.
    # Disable queue side-effects in this unit-level service spec.
    allow(ReindexProductFiltersJob).to receive(:perform_later)
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
    # `package_volume` is stored in liters.
    # `europost_max_volume_m3` in this spec is 0.25, so we need volume_m3 > 0.25 => liters > 250.
    product = create(:product, weight: 5, package_volume: 300.0, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
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


  it "fails by dimensions sum even when max side fits" do
    product = create(:product, weight: 5, package_volume: nil, package_dimensions: "80 x 60 x 50 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(false)
    expect(result[:ineligible_reason]).to eq("max_dimensions_sum_exceeded")
    expect(result[:max_dimensions_sum_cm]).to eq(190.0)
  end

  it "creates one parcel per physical package and cart quantity" do
    product = create(
      :product,
      weight: 1,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: nil,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "width" => "10 см", "height" => "20 см", "length" => "30 см", "weight" => "1.5 кг", "count" => 2 }
            ]
          }
        }
      }
    )
    add_item(product, quantity: 3)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:parcels].size).to eq(6)
    expect(result[:total_weight_kg]).to eq(9.0)
  end

  it "quantity greater than one creates multiple parcels" do
    product = create(:product, weight: 5, package_volume: 0.02, package_dimensions: "20 x 30 x 40 cm", dimensions: nil, full_attributes: {})
    add_item(product, quantity: 3)

    result = described_class.call(cart)

    expect(result[:parcels].size).to eq(3)
    expect(result[:total_weight_kg]).to eq(15.0)
  end

  it "recovers small package weight when imported weight is grams stored as kg" do
    product = create(
      :product,
      weight: 330,
      package_volume: nil,
      package_dimensions: "10 x 2 x 20 cm",
      dimensions: nil,
      full_attributes: {
        "measurements_modal" => {
          "packages" => [
            {
              "measurements" => [
                { "name" => "Вес", "measure" => "0.33 кг" },
                { "name" => "Упаковка(-и)", "measure" => "1" }
              ]
            }
          ]
        }
      }
    )
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:total_weight_kg]).to eq(0.33)
  end

  it "uses package diameter as width and height when width is missing (rolled IKEA packaging)" do
    product = create(
      :product,
      weight: 0.46,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: "130 × 170 cm",
      full_attributes: {
        "measurements_modal" => {
          "packages" => [
            {
              "measurements" => [
                { "name" => "Длина", "measure" => "29 см" },
                { "name" => "Диаметр", "measure" => "12 см" },
                { "name" => "Вес", "measure" => "0.46 кг" },
                { "name" => "Упаковка(-и)", "measure" => "1" }
              ]
            }
          ]
        }
      }
    )
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:max_dimension_cm]).to eq(29.0)
    parcel = result[:parcels].first
    expect(parcel[:width_cm]).to eq(12.0)
    expect(parcel[:height_cm]).to eq(12.0)
    expect(parcel[:depth_cm]).to eq(29.0)
  end

  it "uses package diameter as second side when round flat package has height but no length" do
    product = create(
      :product,
      weight: 0.13,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: nil,
      full_attributes: {
        "measurements_modal" => {
          "packages" => [
            {
              "measurements" => [
                { "name" => "Высота", "measure" => "8 см" },
                { "name" => "Диаметр", "measure" => "30 см" },
                { "name" => "Вес", "measure" => "0.13 кг" },
                { "name" => "Упаковка(-и)", "measure" => "1" }
              ]
            }
          ]
        }
      }
    )
    add_item(product, quantity: 8)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:parcels].size).to eq(8)
    expect(result[:total_weight_kg]).to eq(1.04)
    expect(result[:total_volume_m3]).to eq(0.0576)

    parcel = result[:parcels].first
    expect(parcel[:width_cm]).to eq(30.0)
    expect(parcel[:height_cm]).to eq(8.0)
    expect(parcel[:depth_cm]).to eq(30.0)
  end

  it "uses structured package dimensions instead of arbitrary numbers from full attributes" do
    product = create(
      :product,
      weight: 1,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: nil,
      full_attributes: {
        "measurements_modal" => {
          "packages" => [
            {
              "name" => "Small box",
              "article_number" => { "value" => "805.415.94" },
              "measurements" => [
                { "name" => "Ширина", "measure" => "10 см" },
                { "name" => "Высота", "measure" => "2 см" },
                { "name" => "Длина", "measure" => "20 см" },
                { "name" => "Вес", "measure" => "1 кг" },
                { "name" => "Упаковка(-и)", "measure" => "1" }
              ]
            }
          ]
        }
      }
    )
    add_item(product, quantity: 1)

    result = described_class.call(cart)

    expect(result[:eligible_for_europost]).to be(true)
    expect(result[:max_dimension_cm]).to eq(20.0)
    expect(result[:total_volume_m3]).to eq(0.0004)
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

  context "with Europost bulky defaults" do
    before do
      allow(CalculatorSetting).to receive(:get).and_call_original
      allow(CalculatorSetting).to receive(:get).with("europost_max_weight_kg").and_return(nil)
      allow(CalculatorSetting).to receive(:get).with("europost_max_volume_m3").and_return(nil)
      allow(CalculatorSetting).to receive(:get).with("europost_max_dimension_cm").and_return(nil)
      allow(CalculatorSetting).to receive(:get).with("europost_max_dimensions_sum_cm").and_return(nil)
      allow(CalculatorSetting).to receive(:get).with("europost_max_side_dimensions_cm").and_return(nil)
    end

    it "exposes bulky legal-entity limits as code defaults" do
      expect(described_class.europost_limits).to include(
        max_weight_kg: 50.0,
        max_volume_m3: 2.0,
        max_dimension_cm: 250.0,
        max_dimensions_sum_cm: 350.0
      )
    end

    it "keeps multi-package sofa under 50 kg eligible for Europost courier pricing" do
      # LILLEHEM 19471279 packaging: longest parcel 74×23×144 cm / 17.7 kg.
      # Old standard limits (105 / 180) forced ikeya_delivery callback instead of price.
      product = create(
        :product,
        weight: 45.4,
        package_volume: nil,
        package_dimensions: nil,
        dimensions: "73 x 152 x 76 cm",
        full_attributes: {
          "dimensions_map" => {
            "packaging" => {
              "details" => [
                { "width" => "74 см", "height" => "23 см", "length" => "144 см", "weight" => "17.70 кг", "count" => 1 },
                { "width" => "15 см", "height" => "5 см", "length" => "23 см", "weight" => "1.16 кг", "count" => 1 },
                { "width" => "54 см", "height" => "17 см", "length" => "76 см", "weight" => "6.00 кг", "count" => 4 },
                { "width" => "38 см", "height" => "3 см", "length" => "57 см", "weight" => "0.90 кг", "count" => 1 },
                { "width" => "25 см", "height" => "3 см", "length" => "37 см", "weight" => "0.41 кг", "count" => 4 }
              ]
            }
          }
        }
      )
      add_item(product, quantity: 1)

      result = described_class.call(cart)

      expect(result[:eligible_for_europost]).to be(true)
      expect(result[:ineligible_reason]).to be_nil
      expect(result[:parcels].size).to eq(11)
      expect(result[:total_weight_kg]).to eq(45.4)
      expect(result[:max_dimension_cm]).to eq(144.0)
      expect(result[:max_dimensions_sum_cm]).to eq(241.0)
      expect(result[:parcels].all? { |parcel| parcel[:eligible_for_europost] }).to be(true)
    end
  end
end
