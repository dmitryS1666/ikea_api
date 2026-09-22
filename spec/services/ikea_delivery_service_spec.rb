# frozen_string_literal: true

require "rails_helper"

RSpec.describe IkeaDeliveryService do
  def product_with_package(weight: 2.0, sides: [20, 30, 40], is_parcel: false)
    details = {
      "weight" => "#{weight} кг",
      "count" => 1
    }
    if sides
      details["width"] = "#{sides[0]} см"
      details["height"] = "#{sides[1]} см"
      details["length"] = "#{sides[2]} см"
    end

    create(
      :product,
      weight: weight,
      is_parcel: is_parcel,
      delivery_cost: nil,
      delivery_cost_manual: false,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [details]
          }
        }
      }
    )
  end

  def write_config!(methods)
    CalculatorSetting.set(
      "ikea_delivery_config",
      {
        "destination" => {
          "address" => "ul. Octowa 24",
          "postal_code" => "15-399",
          "city" => "Białystok",
          "country" => "PL",
          "zone" => "A"
        },
        "use_member_prices" => false,
        "methods" => methods
      },
      setting_type: "json"
    )
  end

  def write_production_defaults!
    CalculatorSetting.set(
      "ikea_delivery_config",
      CalculatorSetting.default_ikea_delivery_config,
      setting_type: "json"
    )
  end

  it "returns nil when no methods are configured" do
    write_config!([])
    expect(described_class.quote(product_with_package)).to be_nil
  end

  it "gives an IKEA parcel up to 30 kg free GLS pickup and skips paid GLS courier" do
    write_config!(
      [
        {
          "code" => "gls_home_0_25",
          "name" => "GLS courier",
          "service_code" => "ikea_gls",
          "enabled" => true,
          "cost_pln" => 19.99,
          "priority" => 1,
          "requires_product_eligibility" => true,
          "constraints" => { "max_weight_kg" => 25, "max_length_cm" => 120 }
        },
        {
          "code" => "transport",
          "name" => "Transport",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 69.0,
          "priority" => 10,
          "constraints" => { "max_weight_kg" => 50 }
        }
      ]
    )

    parcel = described_class.quote(product_with_package(weight: 12.35, is_parcel: true))
    expect(parcel[:delivery_type]).to eq("gls_point")
    expect(parcel[:cost_pln]).to eq(BigDecimal("0"))

    cargo = described_class.quote(product_with_package(weight: 12.35, is_parcel: false))
    expect(cargo[:delivery_type]).to eq("ikea_transport")
    expect(cargo[:cost_pln]).to eq(BigDecimal("69.0"))
  end

  it "skips methods that do not fit package dimensions even if they are cheaper" do
    write_config!(
      [
        {
          "code" => "paczkomat",
          "enabled" => true,
          "cost_pln" => 9.0,
          "priority" => 1,
          "constraints" => { "max_length_cm" => 10, "max_width_cm" => 10, "max_height_cm" => 10 }
        },
        {
          "code" => "transport",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 79.0,
          "priority" => 10,
          "constraints" => { "max_weight_kg" => 1000 }
        }
      ]
    )

    quote = described_class.quote(product_with_package(weight: 5.0, sides: [80, 40, 30]))
    expect(quote[:delivery_type]).to eq("ikea_transport")
    expect(quote[:cost_pln]).to eq(BigDecimal("79.0"))
  end

  it "does not invent a cost for a method without cost_pln" do
    write_config!(
      [
        {
          "code" => "gls",
          "enabled" => true,
          "priority" => 1,
          "constraints" => { "max_weight_kg" => 20 }
        }
      ]
    )

    expect(described_class.quote(product_with_package)).to be_nil
  end

  it "accepts price_pln as an alias for cost_pln" do
    write_config!(
      [
        {
          "code" => "transport",
          "enabled" => true,
          "price_pln" => 99.0,
          "priority" => 30,
          "max_weight_kg" => 50
        }
      ]
    )

    quote = described_class.quote(product_with_package(weight: 10.0, sides: nil))
    expect(quote[:cost_pln]).to eq(BigDecimal("99.0"))
  end

  describe "IKEA.pl regular tariffs zone A" do
    before { write_production_defaults! }

    it "uses free GLS pickup for an IKEA parcel up to 30 kg" do
      quote = described_class.quote(product_with_package(weight: 4.0, sides: [20, 30, 40], is_parcel: true))
      expect(quote[:delivery_type]).to eq("gls_point")
      expect(quote[:cost_pln]).to eq(BigDecimal("0"))
    end

    it "charges without-carry 69 PLN when the product is not an IKEA parcel" do
      quote = described_class.quote(product_with_package(weight: 4.0, sides: [20, 30, 40], is_parcel: false))
      expect(quote[:delivery_type]).to eq("ikea_transport")
      expect(quote[:cost_pln]).to eq(BigDecimal("69.0"))
    end

    it "keeps free GLS pickup at 30 kg and switches to 69 PLN just above it" do
      at_limit = described_class.quote(product_with_package(weight: 30.0, sides: [40, 40, 40], is_parcel: true))
      expect(at_limit[:cost_pln]).to eq(BigDecimal("0"))

      above = described_class.quote(product_with_package(weight: 30.01, sides: [40, 40, 40], is_parcel: true))
      expect(above[:cost_pln]).to eq(BigDecimal("69.0"))
    end

    it "uses without-carry 69 PLN when the box exceeds paid GLS dimensions" do
      quote = described_class.quote(product_with_package(weight: 10.0, sides: [70, 90, 210], is_parcel: false))
      expect(quote[:delivery_type]).to eq("ikea_transport")
      expect(quote[:cost_pln]).to eq(BigDecimal("69.0"))
    end

    it "uses without-carry 99 PLN for 50.01–100 kg" do
      quote = described_class.quote(product_with_package(weight: 80.0, sides: [80, 80, 200], is_parcel: false))
      expect(quote[:cost_pln]).to eq(BigDecimal("99.0"))
    end

    it "uses without-carry 159 PLN for 100.01–200 kg" do
      quote = described_class.quote(product_with_package(weight: 120.0, sides: [80, 80, 200], is_parcel: false))
      expect(quote[:cost_pln]).to eq(BigDecimal("159.0"))
    end
  end
end
