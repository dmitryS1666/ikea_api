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

  describe ".refresh! parcel flag" do
    let(:category) { create(:category) }

    it "stores isParcel from the PL page and recalculates delivery" do
      product = create(
        :product,
        category: category,
        sku: "30535109",
        item_no: "30535109",
        url: "https://www.ikea.com/pl/pl/p/-30535109/",
        quantity: 1,
        price: 10,
        is_parcel: nil,
        delivery_cost: 69
      )
      allow(PlDetailsFetcher).to receive(:shelf_snapshot).and_return(
        price: 499,
        availability: { "status" => "IN_STOCK" },
        canonical_url: "https://www.ikea.com/pl/pl/p/-30535109/",
        is_parcel: true
      )
      allow(IkeaDeliveryService).to receive(:quote).and_return(
        delivery_type: "gls_point",
        delivery_name: "GLS",
        delivery_reason: "parcel",
        cost_pln: BigDecimal("0")
      )

      described_class.refresh!(product)

      product.reload
      expect(product.is_parcel).to be true
      expect(product.delivery_cost).to eq(0)
      expect(product.delivery_type).to eq("gls_point")
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
