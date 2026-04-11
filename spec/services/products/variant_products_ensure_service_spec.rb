# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::VariantProductsEnsureService do
  describe ".variant_skus_from_variants_payload" do
    it "collects sku from each variant item" do
      payload = [
        {
          "type" => "color",
          "data" => [
            { "color" => "A", "item" => { "sku" => "s11111111", "price" => "1" } },
            { "color" => "B", "item" => { "sku" => "s22222222" } }
          ]
        }
      ].to_json

      expect(described_class.variant_skus_from_variants_payload(payload)).to contain_exactly("s11111111", "s22222222")
    end

    it "returns empty on invalid json" do
      expect(described_class.variant_skus_from_variants_payload("{")).to eq([])
    end
  end
end
