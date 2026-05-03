# frozen_string_literal: true

require "rails_helper"

RSpec.describe CategoryRelatedProductList do
  let(:category) { Category.create!(ikea_id: "999992", name: "Cat B") }

  describe ".skus_for_product" do
    it "returns category list when primary category has rows" do
      CategoryRelatedProductList.create!(
        category_id: category.ikea_id,
        related_products: %w[10101010 20202020]
      )
      product = Product.create!(
        sku: "s30303030",
        name: "Item",
        category_id: category.ikea_id,
        price: 1.0,
        quantity: 1
      )

      expect(described_class.skus_for_product(product)).to eq(%w[10101010 20202020])
    end

    it "falls back to joined category when primary has no list" do
      cat_a = Category.create!(ikea_id: "999993", name: "A")
      cat_b = Category.create!(ikea_id: "999994", name: "B")
      CategoryRelatedProductList.create!(category_id: cat_b.ikea_id, related_products: %w[90909090])

      product = Product.create!(
        sku: "s40404040",
        name: "Item",
        category_id: cat_a.ikea_id,
        price: 1.0,
        quantity: 1
      )
      CategoryProduct.create!(product: product, category_id: cat_b.ikea_id)

      product.reload
      expect(described_class.skus_for_product(product)).to eq(%w[90909090])
    end
  end
end
