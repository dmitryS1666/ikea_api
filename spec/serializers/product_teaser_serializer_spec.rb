require "rails_helper"
require "securerandom"

RSpec.describe ProductTeaserSerializer do
  describe "category_id attribute" do
    let!(:root_category) do
      Category.create!(
        ikea_id: "root-#{SecureRandom.hex(4)}",
        name: "Root Category",
        parent_ids: []
      )
    end

    let!(:child_category) do
      Category.create!(
        ikea_id: "child-#{SecureRandom.hex(4)}",
        name: "Child Category",
        parent_ids: [root_category.ikea_id]
      )
    end

    let(:product) do
      Product.create!(
        sku: "SKU-#{SecureRandom.uuid}",
        name: "Serializable teaser product",
        category_id: child_category.ikea_id,
        quantity: 10,
        price: 100.0
      )
    end

    it "returns original category_id by default" do
      serialized = described_class.new(product, params: {}).serializable_hash

      expect(serialized[:data][:attributes][:category_id]).to eq(child_category.ikea_id)
    end

    it "returns root category_id when root_categories_only is enabled" do
      serialized = described_class.new(product, params: { root_categories_only: true }).serializable_hash

      expect(serialized[:data][:attributes][:category_id]).to eq(root_category.ikea_id)
    end
  end
end
