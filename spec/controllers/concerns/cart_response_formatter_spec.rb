# frozen_string_literal: true

require "rails_helper"

RSpec.describe CartResponseFormatter do
  let(:helper) do
    Class.new do
      include CartResponseFormatter
    end.new
  end

  describe "#pricing_payload" do
    it "maps CartPricingService fields to cart API pricing keys" do
      line = {
        quantity: 2,
        unit_price_byn_before_discount: 100.0,
        unit_price_byn: 90.0,
        unit_discount_byn: 10.0,
        line_total_byn: 180.0,
        line_discount_byn: 20.0,
        customs_duty_byn: 5.0,
        customs_fee_byn: 1.0,
        customs_total_byn: 6.0,
        promo_applied: true,
        promo_code: "SALE"
      }

      payload = helper.send(:pricing_payload, line)

      expect(payload[:unit_price_old_byn]).to eq("100.00")
      expect(payload[:unit_price_new_byn]).to eq("90.00")
      expect(payload[:line_total_old_byn]).to eq("200.00")
      expect(payload[:line_total_new_byn]).to eq("180.00")
      expect(payload[:promo_code]).to eq("SALE")
    end

    it "returns zero strings for a missing pricing line" do
      payload = helper.send(:pricing_payload, {})

      expect(payload[:unit_price_new_byn]).to eq("0.00")
      expect(payload[:line_total_new_byn]).to eq("0.00")
    end
  end

  describe "#format_totals" do
    it "derives subtotal_old_byn from subtotal_new and discount when absent" do
      totals = helper.send(
        :format_totals,
        subtotal_new_byn: 500.0,
        discount_total_byn: 50.0,
        items_total_byn: 400.0,
        delivery_total_byn: 171.0,
        delivery_poland_byn: 50.0,
        delivery_to_belarus_byn: 121.0,
        total_byn: 900.0,
        customs_duty_byn: 0,
        customs_fee_byn: 0,
        customs_total_byn: 0,
        total_weight_kg: 179.94
      )

      expect(totals[:subtotal_old_byn]).to eq("550.00")
      expect(totals[:delivery_total_byn]).to eq("171.00")
      expect(totals[:delivery_to_belarus_byn]).to eq("121.00")
    end
  end

  describe "#format_cart_delivery" do
    it "exposes internal cart delivery breakdown and method availability" do
      totals = {
        total_weight_kg: 25.0,
        delivery_poland_byn: 10.0,
        delivery_to_belarus_byn: 90.0,
        delivery_total_byn: 100.0
      }
      options = {
        cart_vgh: { eligible_for_europost: false, ineligible_reason: "max_weight_exceeded" },
        methods: [
          { code: "europost_pickup", available: false, reason: "max_weight_exceeded" },
          { code: "ikeya_delivery", available: true, reason: nil }
        ]
      }

      delivery = helper.send(:format_cart_delivery, totals, options)

      expect(delivery[:pricing_source]).to eq("internal_cart")
      expect(delivery[:delivery_to_belarus_byn]).to eq("90.00")
      expect(delivery[:europost_eligible]).to be(false)
      expect(delivery[:available_methods].size).to eq(2)
    end
  end
end
