# frozen_string_literal: true

require "rails_helper"

RSpec.describe CartDisplayTotalsService do
  describe ".for_summary" do
    it "adapts internal pricing totals to the frontend cart summary contract" do
      totals = described_class.for_summary(
        subtotal_new_byn: 4085.64,
        items_total_byn: 4085.64,
        delivery_to_belarus_byn: 128.56,
        delivery_total_byn: 128.56,
        discount_total_byn: 0.0,
        customs_total_byn: 852.21,
        total_weight_kg: 163.59,
        total_byn: 4622.76
      )

      expect(totals[:subtotal_new_byn]).to eq(4494.20)
      expect(totals[:items_total_byn]).to eq(4494.20)
      expect(totals[:delivery_to_belarus_byn]).to eq(128.56)
      expect(totals[:delivery_total_byn]).to eq(128.56)
      expect(totals[:total_byn]).to eq(4622.76)
      expect(totals[:final_total_byn]).to eq(4622.76)
      expect(totals[:customs_total_byn]).to eq(852.21)
    end

    it "keeps the visible cart formula stable when a discount is present" do
      totals = described_class.for_summary(
        delivery_to_belarus_byn: 100.0,
        delivery_total_byn: 100.0,
        discount_total_byn: 25.0,
        total_byn: 975.0
      )

      expect(totals[:subtotal_new_byn] + totals[:delivery_total_byn] - totals[:discount_total_byn]).to eq(totals[:total_byn])
    end

    it "prefers the sum of visible line totals for subtotal_new_byn" do
      totals = described_class.for_summary(
        storefront_subtotal_byn: 2620.50,
        delivery_to_belarus_byn: 212.12,
        discount_total_byn: 0.0,
        total_byn: 2832.62
      )

      expect(totals[:subtotal_new_byn]).to eq(2620.50)
    end
  end
end
