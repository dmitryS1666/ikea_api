require "rails_helper"

RSpec.describe Products::FilterValuesIndexer do
  describe "#reindex!" do
    it "calculates local price filters" do
      category = create(:category, ikea_id: "700403", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [
            { "id" => "PRICE_19900_19901", "name" => "199 zl" },
            { "id" => "PRICE_29900_29901", "name" => "299 zl" }
          ]
        }
      ])
      product = create(:product, price: 199)
      category.products_through_categories << product

      described_class.new(category).reindex!

      expect(
        ProductFilterValue.where(
          product_id: product.id,
          category_id: category.ikea_id,
          parameter: "f-price-buckets",
          value_id: "PRICE_19900_19901"
        )
      ).to exist
    end

    it "does not infer IKEA color facets from product text" do
      category = create(:category, ikea_id: "700999", available_filters: [
        {
          "parameter" => "f-colors",
          "values" => [{ "id" => "10028", "name" => "szary" }]
        }
      ])
      product = create(:product, full_attributes: { "Kolor" => "Szary" })
      category.products_through_categories << product

      described_class.new(category).reindex!

      expect(ProductFilterValue.where(parameter: "f-colors", value_id: "10028")).not_to exist
    end

    it "preserves exact IKEA facet rows while rebuilding local filters" do
      category = create(:category, ikea_id: "700888", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [{ "id" => "PRICE_19900_19901", "name" => "199 zl" }]
        },
        {
          "parameter" => "f-colors",
          "values" => [{ "id" => "10028", "name" => "Серый" }]
        }
      ])
      product = create(:product, price: 199)
      category.products_through_categories << product
      exact_row = ProductFilterValue.create!(
        product: product,
        category: category,
        parameter: "f-colors",
        value_id: "10028"
      )

      described_class.new(category).reindex!

      expect(ProductFilterValue.exists?(exact_row.id)).to eq(true)
      expect(ProductFilterValue.where(product: product, parameter: "f-price-buckets")).to exist
    end
  end

  describe "#reindex_product" do
    it "updates local rows for one product without deleting IKEA memberships" do
      category = create(:category, ikea_id: "700777", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [{ "id" => "PRICE_19900_19901", "name" => "199 zl" }]
        },
        {
          "parameter" => "f-series",
          "values" => [{ "id" => "HAUGA", "name" => "HAUGA" }]
        }
      ])
      product = create(:product, price: 199)
      category.products_through_categories << product
      ikea_row = ProductFilterValue.create!(
        product: product,
        category: category,
        parameter: "f-series",
        value_id: "HAUGA"
      )

      described_class.new(category).reindex_product(product)

      expect(ProductFilterValue.exists?(ikea_row.id)).to eq(true)
      expect(ProductFilterValue.where(product: product, parameter: "f-price-buckets")).to exist
    end
  end
end
