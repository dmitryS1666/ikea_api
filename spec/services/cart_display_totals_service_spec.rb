# frozen_string_literal: true

require "rails_helper"

RSpec.describe CartDisplayTotalsService do
  describe ".for_summary" do
    it "includes customs and last-mile only, without adding WC twice" do
      totals = described_class.for_summary(
        items_total_byn: 4085.64,
        subtotal_new_byn: 4085.64,
        delivery_to_belarus_byn: 128.56,
        delivery_poland_byn: 50.0,
        local_delivery_total_byn: 12.43,
        discount_total_byn: 0.0,
        customs_total_byn: 852.21,
        total_weight_kg: 163.59
      )

      expect(totals[:items_total_byn]).to eq(4085.64)
      expect(totals[:subtotal_new_byn]).to eq(4085.64)
      expect(totals[:delivery_to_belarus_byn]).to eq(128.56)
      expect(totals[:delivery_total_byn]).to eq(12.43)
      expect(totals[:customs_total_byn]).to eq(852.21)
      expect(totals[:total_byn]).to eq((4085.64 + 852.21 + 12.43).round(2))
      expect(totals[:final_total_byn]).to eq(totals[:total_byn])
    end

    it "subtracts promo from items only, not from customs" do
      totals = described_class.for_summary(
        items_total_byn: 1000.0,
        discount_total_byn: 25.0,
        customs_total_byn: 70.0,
        local_delivery_total_byn: 0.0
      )

      expect(totals[:total_byn]).to eq(1045.0)
    end

    it "keeps WC/D_IKEA as breakdown that is not added again" do
      totals = described_class.for_summary(
        items_total_byn: 1034.70,
        delivery_to_belarus_byn: 20.49,
        delivery_poland_byn: 15.0,
        discount_total_byn: 0.0,
        customs_total_byn: 0.0
      )

      expect(totals[:subtotal_new_byn]).to eq(1034.70)
      expect(totals[:delivery_total_byn]).to eq(0.0)
      expect(totals[:total_byn]).to eq(1034.70)
    end
  end
end
