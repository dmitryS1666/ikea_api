# frozen_string_literal: true

require "rails_helper"

RSpec.describe IkeaDeliveryService do
  def product_with_package(weight: 2.0, sides: [20, 30, 40])
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

  it "picks the cheapest enabled method that matches package limits" do
    write_config!(
      [
        {
          "code" => "gls",
          "name" => "GLS courier",
          "service_code" => "ikea_gls",
          "enabled" => true,
          "cost_pln" => 19.99,
          "priority" => 1,
          "requires_product_eligibility" => true,
          "constraints" => { "max_weight_kg" => 20, "max_length_cm" => 120 }
        },
        {
          "code" => "transport",
          "name" => "Transport",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 79.0,
          "priority" => 10,
          "constraints" => { "max_weight_kg" => 1000 }
        }
      ]
    )

    quote = described_class.quote(product_with_package(weight: 2.0))
    expect(quote[:delivery_type]).to eq("ikea_gls")
    expect(quote[:cost_pln]).to eq(BigDecimal("19.99"))
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

    it "uses GLS 19.99 for a small parcel-eligible product, not Family 7 PLN" do
      quote = described_class.quote(product_with_package(weight: 4.0, sides: [20, 30, 40]))
      expect(quote[:delivery_type]).to eq("ikea_gls")
      expect(quote[:cost_pln]).to eq(BigDecimal("19.99"))
    end

    it "does not apply GLS 19.99 by weight alone when box dimensions are missing" do
      quote = described_class.quote(product_with_package(weight: 4.0, sides: nil))
      expect(quote[:delivery_type]).to eq("ikea_transport")
      expect(quote[:cost_pln]).to eq(BigDecimal("99.0"))
    end

    it "uses GLS 19.99 at the 25 kg boundary and 29.99 just above it" do
      at_limit = described_class.quote(product_with_package(weight: 25.0, sides: [40, 40, 40]))
      expect(at_limit[:cost_pln]).to eq(BigDecimal("19.99"))

      above = described_class.quote(product_with_package(weight: 25.01, sides: [40, 40, 40]))
      expect(above[:cost_pln]).to eq(BigDecimal("29.99"))
    end

    it "falls back to transport when the box exceeds GLS dimensions" do
      quote = described_class.quote(product_with_package(weight: 10.0, sides: [70, 90, 210]))
      expect(quote[:delivery_type]).to eq("ikea_transport")
      expect(quote[:cost_pln]).to eq(BigDecimal("99.0"))
    end

    it "uses transport 139 PLN for 50.01–100 kg" do
      quote = described_class.quote(product_with_package(weight: 80.0, sides: [80, 80, 200]))
      expect(quote[:cost_pln]).to eq(BigDecimal("139.0"))
    end
  end
end
