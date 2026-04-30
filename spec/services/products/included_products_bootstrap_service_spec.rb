# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::IncludedProductsBootstrapService do
  describe ".ensure!" do
    let(:parent) { create(:product, sku: "s11111111", included_products: ["12345678"]) }

    it "enriches existing included product when it is incomplete" do
      child = create(:product, sku: "s12345678", item_no: "12345678", name: "IKEA 12345678", price: 0, quantity: 0)

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: true })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      expect(Products::ExtendedAttributesFetchService).to have_received(:fetch_for_product).with(
        child,
        results_jsonl_row: nil,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true,
        strip_listing_relations: true
      )
    end

    it "skips enrich for existing included product with complete card" do
      create(
        :product,
        sku: "s12345678",
        item_no: "12345678",
        name: "BILLY",
        price: 100,
        quantity: 1,
        weight: "10 kg",
        dimensions: "100x50x30",
        materials: "wood",
        content: "desc"
      )

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product)

      described_class.ensure!(parent)

      expect(Products::ExtendedAttributesFetchService).not_to have_received(:fetch_for_product)
    end
  end
end
