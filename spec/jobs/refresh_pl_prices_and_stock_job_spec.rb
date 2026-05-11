# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshPlPricesAndStockJob do
  describe ".pl_price_stock_lookup_skus" do
    it "разворачивает артикул с точками в варианты для БД" do
      skus = described_class.pl_price_stock_lookup_skus("194.851.39")
      expect(skus).to include("19485139", "s19485139")
    end

    it "принимает 8 цифр как есть" do
      skus = described_class.pl_price_stock_lookup_skus("19485139")
      expect(skus).to include("19485139")
    end
  end

  describe ".products_relation_for_pl_refresh" do
    it "ограничивает выборку по SKU" do
      create(:product, sku: "19485139", name: "A")
      create(:product, sku: "00528940", name: "B")

      rel = described_class.products_relation_for_pl_refresh("194.851.39")
      expect(rel.pluck(:sku)).to contain_exactly("19485139")
    end
  end
end
