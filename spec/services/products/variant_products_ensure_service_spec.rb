# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::VariantProductsEnsureService do
  describe ".ensure!" do
    let(:category) { create(:category, ikea_id: "701199") }
    let(:variants_payload) do
      [{ "type" => "color", "data" => [{ "item" => { "sku" => "s87654321" } }] }].to_json
    end
    let(:parent) do
      create(
        :product,
        sku: "s11111111",
        name: "Parent sofa",
        variants_payload: variants_payload,
        category_id: category.ikea_id
      )
    end

    it "does not keep a new variant row when enrich leaves placeholder name" do
      allow(Products::ExtendedAttributesFetchService).to receive(:fetch_for_product).and_return({ updated: false })

      expect do
        described_class.ensure!(parent, category: category)
      end.not_to(change { Product.where(sku: "s87654321").count })

      expect(Product.find_by(sku: "s87654321")).to be_nil
    end
  end

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

    it "expands item.sku when API returns an array of listing skus" do
      payload = [
        {
          "type" => "color",
          "data" => [
            { "item" => { "sku" => %w[s11111111 s22222222] } }
          ]
        }
      ].to_json

      expect(described_class.variant_skus_from_variants_payload(payload)).to contain_exactly("s11111111", "s22222222")
    end
  end
end
