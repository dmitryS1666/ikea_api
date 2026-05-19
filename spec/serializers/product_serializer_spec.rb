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

  describe "related_products attribute" do
    it "filters out SKUs without available stock" do
      category = Category.create!(ikea_id: "cat-rel-1", name: "Cat", parent_ids: [])
      product = create(:product, sku: "srel00001", category_id: category.ikea_id, related_products: %w[srel00002 srel00003])
      create(:product, sku: "srel00002", quantity: 4)
      create(:product, sku: "srel00003", quantity: 0)

      serialized = described_class.new(product, params: { detail: true }).serializable_hash
      related = serialized[:data][:attributes][:related_products]

      expect(related).to eq(["srel00002"])
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

  describe ".build_packages_for_customer_payload" do
    it "builds packages from packaging.details when measurements_modal has no packages" do
      size = {
        "packaging" => {
          "desc" => "BÅRSLÖV БОРСЛЁВ, 805.415.94",
          "details" => [
            {
              "width" => "83 см",
              "height" => "48 см",
              "length" => "158 см",
              "weight" => "44.40 кг",
              "count" => 1,
              "label" => "BÅRSLÖV БОРСЛЁВ · 3-местный диван-кровать с козеткой · 805.415.94"
            }
          ]
        }
      }
      packages = described_class.build_packages_for_customer_payload(size, nil)
      expect(packages.size).to eq(1)
      expect(packages[0]["name"]).to include("BÅRSLÖV")
      expect(packages[0]["type_name"]).to include("3-местный")
      expect(packages[0]["article_number"]["value"]).to eq("805.415.94")
      by_name = packages[0]["measurements"].index_by { |m| m["name"] }
      expect(by_name["Ширина"]["measure"]).to eq("83 см")
      expect(by_name["Упаковка(-и)"]["measure"]).to eq("1")
    end

    it "prefers measurements_modal.packages when present" do
      mm = {
        "packages" => [
          {
            "name" => "P Name",
            "type_name" => "P Type",
            "measurements" => [{ "name" => "Ширина", "measure" => "10 см" }],
            "article_number" => { "label" => "Номер товара", "value" => "111.222.33" }
          }
        ]
      }
      size = { "packaging" => { "desc" => nil, "details" => [{ "width" => "99 см" }] } }
      packages = described_class.build_packages_for_customer_payload(size, mm)
      expect(packages[0]["name"]).to eq("P Name")
      expect(packages[0]["measurements"].first["measure"]).to eq("10 см")
    end
  end

  describe ".dedupe_instruction_files / customer_full_attributes_payload instructions" do
    it "removes duplicate document links (same URL, http vs https, trailing slash)" do
      raw = [
        { "url" => "http://example.com/a.pdf", "title" => "A" },
        { "url" => "https://example.com/a.pdf", "title" => "A dup" },
        { "url" => "https://example.com/a.pdf/", "title" => "A dup2" },
        { "url" => "https://example.com/b.pdf", "title" => "B" }
      ]
      block = described_class.build_instructions_block(raw)
      expect(block["files"].size).to eq(2)
      expect(block["files"].map { |f| f["link"] }).to contain_exactly(
        "http://example.com/a.pdf",
        "https://example.com/b.pdf"
      )
    end
  end
end
