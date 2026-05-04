require "rails_helper"

RSpec.describe DeliveryOptionsService do
  describe ".call" do
    let(:cart) { create(:cart) }

    before do
      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
      )
    end

    it "enables europost_pickup and courier when cart passes VGH" do
      product = create(
        :product,
        weight: 10.0,
        package_volume: 0.02,
        package_dimensions: "20 x 30 x 40 cm",
        dimensions: "20 x 30 x 40 cm",
        full_attributes: {}
      )
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 2)

      result = described_class.call(cart)

      expect(result[:cart_vgh][:weight_kg]).to eq(20.0)
      # product.package_volume is stored in liters => divide by 1000 to get m³
      expect(result[:cart_vgh][:volume_m3]).to eq(0.00004)
      expect(result[:cart_vgh][:max_dimension_cm]).to eq(40.0)
      expect(result[:cart_vgh][:eligible_for_europost]).to be(true)
      expect(result[:cart_vgh][:ineligible_reason]).to be_nil

      methods = result[:methods].index_by { |m| m[:code] }
      expect(methods["europost_pickup"][:available]).to be(true)
      expect(methods["courier"][:available]).to be(true)
      expect(methods["ikeya_delivery"][:available]).to be(false)
    end

    it "enables only ikeya_delivery when product VGH is incomplete" do
      product = create(
        :product,
        weight: nil,
        package_volume: nil,
        package_dimensions: nil,
        dimensions: nil,
        full_attributes: {}
      )
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      result = described_class.call(cart)

      expect(result[:cart_vgh][:eligible_for_europost]).to be(false)
      expect(result[:cart_vgh][:ineligible_reason]).to eq("missing_vgh_data")

      methods = result[:methods].index_by { |m| m[:code] }
      expect(methods["europost_pickup"][:available]).to be(false)
      expect(methods["courier"][:available]).to be(false)
      expect(methods["ikeya_delivery"][:available]).to be(true)
    end

    it "counts quantity in cart totals" do
      product = create(
        :product,
        weight: 3.5,
        package_volume: 0.015,
        package_dimensions: "10 x 20 x 30 cm",
        dimensions: "10 x 20 x 30 cm",
        full_attributes: {}
      )
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 4)

      result = described_class.call(cart)

      expect(result[:cart_vgh][:weight_kg]).to eq(14.0)
      # product.package_volume is stored in liters => divide by 1000 to get m³
      expect(result[:cart_vgh][:volume_m3]).to eq(0.00006)
      expect(result[:cart_vgh][:max_dimension_cm]).to eq(30.0)
    end

    it "exposes europost_pickup and courier when ParcelPackingService says eligible" do
      allow(Delivery::ParcelPackingService).to receive(:call).and_return(
        {
          total_weight_kg: 10.0,
          total_volume_m3: 0.02,
          max_dimension_cm: 40.0,
          parcels: [{ weight_kg: 10.0, volume_m3: 0.02, eligible_for_europost: true, ineligible_reason: nil }],
          eligible_for_europost: true,
          ineligible_reason: nil
        }
      )

      result = described_class.call(cart)
      methods = result[:methods].index_by { |m| m[:code] }

      expect(methods["europost_pickup"][:available]).to be(true)
      expect(methods["courier"][:available]).to be(true)
      expect(methods["ikeya_delivery"][:available]).to be(false)
    end

    it "exposes only ikeya_delivery when ParcelPackingService says ineligible" do
      allow(Delivery::ParcelPackingService).to receive(:call).and_return(
        {
          total_weight_kg: 10.0,
          total_volume_m3: 0.02,
          max_dimension_cm: 40.0,
          parcels: [{ weight_kg: 35.0, volume_m3: 0.02, eligible_for_europost: false, ineligible_reason: "max_weight_exceeded" }],
          eligible_for_europost: false,
          ineligible_reason: "max_weight_exceeded"
        }
      )

      result = described_class.call(cart)
      methods = result[:methods].index_by { |m| m[:code] }

      expect(methods["europost_pickup"][:available]).to be(false)
      expect(methods["courier"][:available]).to be(false)
      expect(methods["ikeya_delivery"][:available]).to be(true)
    end

    it "does not require local europost pickup points" do
      product = create(
        :product,
        weight: 1.0,
        package_volume: 1.0,
        package_dimensions: "10 x 10 x 10 cm",
        dimensions: nil,
        full_attributes: {}
      )
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      result = described_class.call(cart)

      expect(PickupPoint.where(provider: "europost")).to be_empty
      expect(result[:cart_vgh][:eligible_for_europost]).to be(true)
      expect(result[:methods].find { |m| m[:code] == "europost_pickup" }[:available]).to be(true)
    end
  end
end
