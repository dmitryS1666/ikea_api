# frozen_string_literal: true

require "rails_helper"

RSpec.describe DeliveryCalculateFinance do
  describe ".call" do
    let(:pln_rate_with_buffer) { 3.0 }

    it "uses internal tables for courier" do
      allow(PolandDeliveryService).to receive(:calculate).with(12.0).and_return(79.0)
      allow(BelarusDeliveryService).to receive(:calculate).with(12.0).and_return(100.0)

      r = described_class.call(
        normalized_delivery_type: DeliveryTypeNormalizer::COURIER,
        weight_kg: 12.0,
        pln_rate_with_buffer: pln_rate_with_buffer,
        parcels: [],
        pickup_point_id: nil
      )

      expect(r[:pricing_source]).to eq("internal_weight_tables")
      expect(r[:poland_delivery_byn]).to eq(237.0)
      expect(r[:delivery_price_byn]).to eq(237.0)
      expect(r[:europost_quote]).to be_nil
    end

    it "zero poland segment for ikeya" do
      allow(PolandDeliveryService).to receive(:calculate).and_return(50.0)
      allow(BelarusDeliveryService).to receive(:calculate).and_return(20.0)

      r = described_class.call(
        normalized_delivery_type: DeliveryTypeNormalizer::IKEYA_DELIVERY,
        weight_kg: 5.0,
        pln_rate_with_buffer: pln_rate_with_buffer,
        parcels: [],
        pickup_point_id: nil
      )

      expect(r[:delivery_price_byn]).to eq(0.0)
      expect(r[:total_delivery_price_byn]).to eq(60.0)
      expect(r[:pricing_source]).to eq("internal_ikeya_poland_zero")
    end

    it "uses Europost quote for europost_pickup when successful" do
      allow(PolandDeliveryService).to receive(:calculate).and_return(10.0)
      allow(BelarusDeliveryService).to receive(:calculate).and_return(5.0)
      allow(EuropostPostalPaymentQuote).to receive(:call).and_return(
        success: true,
        postal_total_byn: 9.99,
        currency: "BYN",
        payload: { "weight" => 1.0 },
        raw: { "total" => 9.99 }
      )

      r = described_class.call(
        normalized_delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        weight_kg: 1.0,
        pln_rate_with_buffer: pln_rate_with_buffer,
        parcels: [{ weight_kg: 1.0, volume_m3: 0.01, width_cm: 10, height_cm: 10, depth_cm: 10 }],
        pickup_point_id: nil
      )

      expect(r[:pricing_source]).to eq("europost_api")
      expect(r[:delivery_price_byn]).to eq(9.99)
      expect(r[:total_delivery_price_byn]).to eq((9.99 + 15.0).round(2))
    end
  end
end
