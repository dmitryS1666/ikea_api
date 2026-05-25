# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::StockAvailability do
  describe ".sale_price?" do
    it "is true for price >= 1" do
      expect(described_class.sale_price?(1)).to be(true)
      expect(described_class.sale_price?("39.99")).to be(true)
    end

    it "is false for nil, zero, and sub-unit prices" do
      expect(described_class.sale_price?(nil)).to be(false)
      expect(described_class.sale_price?(0)).to be(false)
      expect(described_class.sale_price?(0.5)).to be(false)
    end
  end

  describe ".in_stock_quantity?" do
    it "is true for quantity >= 1" do
      expect(described_class.in_stock_quantity?(1)).to be(true)
      expect(described_class.in_stock_quantity?(5)).to be(true)
    end

    it "is false for quantity < 1" do
      expect(described_class.in_stock_quantity?(0)).to be(false)
      expect(described_class.in_stock_quantity?(nil)).to be(false)
    end
  end

  describe ".filter_skus_with_available_stock" do
    it "keeps order and drops out-of-stock skus" do
      in_stock = create(:product, sku: "s11111111", quantity: 3)
      create(:product, sku: "s22222222", quantity: 0)

      result = described_class.filter_skus_with_available_stock(%w[s22222222 s11111111])

      expect(result).to eq([in_stock.sku])
    end
  end
end
