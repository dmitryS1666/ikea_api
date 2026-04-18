# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::PlPriceStockRefreshService do
  describe ".refresh!" do
    let(:category) { create(:category) }

    context "when PL URL cannot be built" do
      it "sets quantity to 0" do
        product = create(:product, category: category, sku: "abc", url: "", item_no: nil, quantity: 999)

        result = described_class.refresh!(product)

        expect(product.reload.quantity).to eq(0)
        expect(result[:reason]).to eq(:no_pl_url)
        expect(result[:updated]).to be true
      end
    end

    context "when IKEA returns HTTP 404 for the PL product page" do
      it "treats as not found and sets quantity to 0" do
        product = create(:product, category: category, sku: "99999999", url: "https://www.ikea.com/pl/pl/p/-/99999999/", quantity: 999)

        allow(PlDetailsFetcher).to receive(:shelf_snapshot).and_raise(StandardError, "HTTP error: 404 Not Found")

        result = described_class.refresh!(product)

        expect(product.reload.quantity).to eq(0)
        expect(result[:reason]).to eq(:empty_snapshot)
        expect(result[:updated]).to be true
      end
    end
  end

  describe ".http_not_found_error?" do
    it "returns true for fetcher-style 404 messages" do
      expect(described_class.http_not_found_error?(StandardError.new("HTTP error: 404 Not Found"))).to be true
    end

    it "returns false for other errors" do
      expect(described_class.http_not_found_error?(StandardError.new("HTTP error: 500"))).to be false
    end
  end
end
