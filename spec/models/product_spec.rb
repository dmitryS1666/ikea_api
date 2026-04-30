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
      allow(PriceCalculationService).to receive(:product_price_byn).and_return(350.0)
    end

    it "puts current SKU first and uses nil price_byn when price is missing" do
      out = product.normalized_variants_for_api
      expect(out).to be_a(Array)
      data = out.first[:data]
      expect(data.first.dig(:item, :sku)).to eq("s29545213")
      expect(data.last.dig(:item, :price_byn)).to be_nil
      expect(data.first.dig(:item, :price_byn)).to be_present
    end

    it "treats variant payload prices as PLN even for LT urls" do
      product.url = "https://www.ikea.com/lt/ru/p/vimle-s29545213/"

      product.normalized_variants_for_api

      expect(PriceCalculationService).to have_received(:product_price_byn).with(
        100.0,
        hash_including(pln_rate: 3.5, buffer: 0, weight_kg: product.weight.to_f, delivery_pln: product.delivery_cost.to_f)
      )
    end

    it "normalizes Polish color labels and armrest phrase to Russian" do
      product.variants_payload = [
        {
          "type" => "color",
          "data" => [
            {
              "color" => "z szerokimi podlokietnikami hillared antracyt",
              "item" => { "sku" => "s11111111", "price" => "100.0", "small_desc_name" => "z szerokimi podlokietnikami hillared antracyt" }
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
end
