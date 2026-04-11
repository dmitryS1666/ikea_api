require "rails_helper"
require "securerandom"

RSpec.describe ProductSerializer do
  describe "breadcrumbs attribute" do
    let(:category) do
      Category.create!(
        ikea_id: "cat-1",
        name: "Primary Category",
        parent_ids: []
      )
    end
    let(:product) do
      Product.create!(
        sku: "SKU-#{SecureRandom.uuid}",
        name: "Serializable Product",
        category_id: category.ikea_id
      )
    end

    before do
      BreadcrumbRule.delete_all
      BreadcrumbRule.create!(entity_type: "product", rule_type: :by_primary_category_only, active: true)
    end

    it "exposes breadcrumbs when detail flag is present" do
      serialized = described_class.new(product, params: { detail: true }).serializable_hash

      expect(serialized[:data][:attributes][:breadcrumbs]).to eq([
        { title: category.name, url: "/category/#{category.ikea_id}" }
      ])
    end

    it "does not include breadcrumbs when detail flag is missing" do
      serialized = described_class.new(product).serializable_hash

      expect(serialized[:data][:attributes]).not_to have_key(:breadcrumbs)
    end
  end

  describe ".materials_hash_from_product_details_modal" do
    it "extracts term/definition pairs from material-and-care section" do
      pdm = {
        "accordion_sections" => [
          {
            "id" => "product-details-material-and-care",
            "material_blocks" => [
              {
                "pairs" => [
                  { "term" => "Мешок:", "definition" => "100% полиэстер" }
                ]
              }
            ]
          }
        ]
      }

      expect(described_class.materials_hash_from_product_details_modal(pdm)).to eq(
        "Мешок" => "100% полиэстер"
      )
    end

    it "uses Состав when term is empty and merges care_blocks" do
      pdm = {
        "accordion_sections" => [
          {
            "id" => "product-details-material-and-care",
            "material_blocks" => [
              {
                "pairs" => [
                  { "term" => "", "definition" => "100% полиэстер (мин. 90 % переработанного материала)" }
                ]
              }
            ],
            "care_blocks" => [
              {
                "header" => "",
                "lines" => ["Машинная стирка, 30°С.", "Не отбеливать."]
              }
            ]
          }
        ]
      }

      expect(described_class.materials_hash_from_product_details_modal(pdm)).to eq(
        "Состав" => "100% полиэстер (мин. 90 % переработанного материала)",
        "Уход" => "Машинная стирка, 30°С.\nНе отбеливать."
      )
    end
  end
end
