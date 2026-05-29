# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product, type: :model do
  describe "#normalized_variants_for_api" do
    let(:product) do
      build(
        :product,
        sku: "s29545213",
        url: "https://www.ikea.com/pl/pl/p/vimle-s29545213/",
        variants_payload: [
          {
            "type" => "color",
            "data" => [
              { "color" => "Other", "item" => { "sku" => "s11111111", "price" => nil } },
              { "color" => "Self", "item" => { "sku" => "s29545213", "price" => "100.0" } }
            ]
          }
        ].to_json
      )
    end

    before do
      allow(ExchangeRate).to receive(:fetch_or_create).and_return(instance_double(ExchangeRate, rate_per_unit: 3.5))
      allow(PriceCalculationService).to receive(:exchange_rate_buffer).and_return(0)
      allow(PriceCalculationService).to receive(:product_storefront_price_byn).and_return(350.0)

      create(:product, sku: "s11111111", quantity: 5)
      create(:product, sku: "s29545213", quantity: 5)
    end

    it "drops variant items that are out of stock" do
      Product.find_by(sku: "s11111111")&.update!(quantity: 0)

      expect(product.normalized_variants_for_api).to be_nil
    end

    it "drops variant items without a sale price" do
      Product.find_by(sku: "s11111111")&.update!(price: nil)

      expect(product.normalized_variants_for_api).to be_nil
    end

    it "puts current SKU first and syncs price from DB when payload price is missing" do
      out = product.normalized_variants_for_api
      expect(out).to be_a(Array)
      data = out.first[:data]
      expect(data.first.dig(:item, :sku)).to eq("s29545213")
      expect(data.last.dig(:item, :sku)).to eq("s11111111")
      expect(data.last.dig(:item, :price)).to eq("100.0")
      expect(data.last.dig(:item, :price_byn)).to be_present
      expect(data.first.dig(:item, :price_byn)).to be_present
    end

    it "drops payload-only variants without price and stock in DB" do
      Product.find_by(sku: "s11111111")&.destroy

      expect(product.normalized_variants_for_api).to be_nil
    end

    it "treats variant payload prices as PLN even for LT urls" do
      product.url = "https://www.ikea.com/lt/ru/p/vimle-s29545213/"

      product.normalized_variants_for_api

      expect(PriceCalculationService).to have_received(:product_storefront_price_byn).with(
        100.0,
        hash_including(pln_rate: 3.5, buffer: 0, weight_kg: product.packaging_weight_kg.to_f, delivery_pln: product.delivery_cost.to_f)
      ).at_least(:once)
    end

    it "normalizes Polish color labels and armrest phrase to Russian" do
      create(:product, sku: "s22222222", quantity: 3)

      product.variants_payload = [
        {
          "type" => "color",
          "data" => [
            {
              "color" => "z szerokimi podlokietnikami hillared antracyt",
              "item" => { "sku" => "s11111111", "price" => "100.0", "small_desc_name" => "z szerokimi podlokietnikami hillared antracyt" }
            },
            {
              "color" => "Other",
              "item" => { "sku" => "s22222222", "price" => "80.0", "small_desc_name" => "Other" }
            }
          ]
        }
      ].to_json

      out = product.normalized_variants_for_api
      color = out.first.dig(:data, 0, :color)

      expect(color).to eq("с широкими подлокотниками hillared антрацит")
    end
  end

  describe "#normalized_variant_skus" do
    it "flattens sku when a variant hash stores multiple skus in an array" do
      p = build(:product, variants: [{ "sku" => %w[s11111111 s22222222] }])
      expect(p.normalized_variant_skus).to contain_exactly("s11111111", "s22222222")
    end
  end

  describe "#sync_variant_sibling_links!" do
    it "writes mutual variant sku lists for every product in the group" do
      a = create(:product, sku: "sva11111", variants: [])
      b = create(:product, sku: "svb22222", variants: [])
      a.variants = ["svb22222"]
      a.save!

      a.sync_variant_sibling_links!

      expect(a.reload.normalized_variant_skus).to eq(["svb22222"])
      expect(b.reload.normalized_variant_skus).to eq(["sva11111"])
    end
  end

  describe "admin variant form fields" do
    it "applies variants_skus_text_for_form into variants" do
      p = build(:product, sku: "s10000001", variants: [])
      p.variants_skus_text_for_form = "s20000002\ns20000002"
      p.valid?
      expect(p.variants).to eq(%w[s20000002])
    end

    it "strips own sku from the list" do
      p = build(:product, sku: "s10000001", variants: [])
      p.variants_skus_text_for_form = "s10000001, s20000002"
      p.valid?
      expect(p.variants).to eq(%w[s20000002])
    end

    it "applies variants_payload_text_for_form as canonical JSON" do
      p = build(:product, sku: "s10000001")
      p.variants_payload_text_for_form = { "type" => "color", "data" => [] }.to_json
      p.valid?
      expect(JSON.parse(p.variants_payload)).to eq("type" => "color", "data" => [])
    end

    it "rejects invalid variants_payload JSON" do
      p = build(:product, sku: "s10000001")
      p.variants_payload_text_for_form = "{"
      expect(p).not_to be_valid
      expect(p.errors[:variants_payload].join).to include("JSON")
    end
  end
end
