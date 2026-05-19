# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::IncludedProductsBootstrapService do
  describe ".ensure!" do
    let(:parent) { create(:product, sku: "s11111111", included_products: ["12345678"]) }

    before do
      allow(PlDetailsFetcher).to receive(:headless_browser_executable_available?).and_return(false)
      allow(PlDetailsFetcher).to receive(:fetch_included_articles).and_return([])
    end

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
        strip_listing_relations: true,
        bundle_component: true
      )
    end

    it "enriches complete included product (bundle components always refreshed)" do
      child = create(
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

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: true })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      expect(Products::ExtendedAttributesFetchService).to have_received(:fetch_for_product).with(
        child,
        hash_including(bundle_component: true)
      )
    end

    it "does not require images to finish bootstrap" do
      child = create(:product, sku: "s60489549", item_no: "60489549", name: "IKEA 60489549", images: [], quantity: 0)

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: true })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      expect(ImageDownloader).not_to have_received(:sync_product_images)
      expect(Products::ExtendedAttributesFetchService).to have_received(:fetch_for_product)
    end

    it "extracts articles from mixed included_products payload formats" do
      parent.update!(
        included_products: [
          { "itemNoGlobal" => "12345678" },
          { "item" => { "sku" => "s87654321" } },
          "{\"sku\":\"s23456789\"}",
          "{:itemNo=>\"34567890\"}"
        ]
      )

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: false })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      expect(Product.find_by(item_no: "12345678")).to be_present
      expect(Product.find_by(item_no: "87654321")).to be_present
      expect(Product.find_by(item_no: "23456789")).to be_present
      expect(Product.find_by(item_no: "34567890")).to be_present
    end

    it "creates s{article} when another product shares item_no but has a different listing sku" do
      parent.update!(included_products: ["60489549"])
      create(
        :product,
        sku: "29537072",
        item_no: "60489549",
        name: "VIMLE parent",
        included_products: %w[60489549 00417621]
      )

      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: true })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      component = Product.find_by(sku: "s60489549")
      expect(component).to be_present
      expect(component.item_no).to eq("60489549")
      expect(Product.find_by(sku: "29537072").id).not_to eq(component.id)
    end

    it "creates children from PL fetch when parent included_products was empty" do
      parent.update!(included_products: [])
      allow(PlDetailsFetcher).to receive(:fetch_included_articles).and_return(%w[60489549 00417621])
      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: true })
      allow(ImageDownloader).to receive(:sync_product_images)

      described_class.ensure!(parent)

      expect(Product.find_by(item_no: "60489549")).to be_present
      expect(Product.find_by(item_no: "00417621")).to be_present
      expect(parent.reload.included_products).to eq(%w[60489549 00417621])
    end
  end
end
