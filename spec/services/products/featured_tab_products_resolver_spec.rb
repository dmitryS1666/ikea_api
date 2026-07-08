require "rails_helper"

RSpec.describe Products::FeaturedTabProductsResolver do
  describe ".call" do
    let!(:root_a) { create(:category, ikea_id: "root_a", parent_ids: []) }
    let!(:root_b) { create(:category, ikea_id: "root_b", parent_ids: []) }
    let!(:product_a) { create(:product, sku: "SKU-A", category_id: root_a.ikea_id, quantity: 10, price: 10) }
    let!(:product_b) { create(:product, sku: "SKU-B", category_id: root_b.ikea_id, quantity: 10, price: 10) }

    it "returns nil when tabs are not configured for list" do
      expect(described_class.call(list_key: :bestsellers)).to be_nil
    end

    it "returns products in tab and sku order with category overrides" do
      create(
        :featured_product_tab,
        list_key: "bestsellers",
        category_id: root_b.ikea_id,
        product_skus: [product_b.sku],
        position: 2
      )
      create(
        :featured_product_tab,
        list_key: "bestsellers",
        category_id: root_a.ikea_id,
        product_skus: [product_a.sku],
        position: 1
      )

      result = described_class.call(list_key: :bestsellers)

      expect(result.products.map(&:sku)).to eq([product_a.sku, product_b.sku])
      expect(result.category_id_overrides).to eq(
        product_a.sku => root_a.ikea_id,
        product_b.sku => root_b.ikea_id
      )
    end
  end
end
