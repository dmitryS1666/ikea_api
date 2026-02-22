require "rails_helper"

RSpec.describe Products::FilterValuesIndexer do
  describe "#reindex!" do
    it "creates product_filter_values for price and measurements" do
      category = create(:category, ikea_id: "700403", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [
            { "id" => "PRICE_19900_19901", "name" => "199 zl" },
            { "id" => "PRICE_29900_29901", "name" => "299 zl" }
          ]
        },
        {
          "parameter" => "f-measurement-buckets",
          "values" => [
            { "id" => "WIDTH_150_160", "name" => "Szerokosc: 150-160 cm" }
          ]
        }
      ])

      product = create(:product,
                       price: 199,
                       full_attributes: { "Szerokość" => "158 cm" })

      category.products_through_categories << product

      described_class.new(category).reindex!

      expect(ProductFilterValue.where(product_id: product.id, category_id: category.ikea_id)).to exist
      expect(ProductFilterValue.where(parameter: "f-price-buckets", value_id: "PRICE_19900_19901")).to exist
      expect(ProductFilterValue.where(parameter: "f-measurement-buckets", value_id: "WIDTH_150_160")).to exist
    end

    it "matches color filters by text values" do
      category = create(:category, ikea_id: "700999", available_filters: [
        {
          "parameter" => "f-colors",
          "values" => [
            { "id" => "10028", "name" => "szary" }
          ]
        }
      ])

      product = create(:product,
                       full_attributes: { "Kolor" => "Szary" })

      category.products_through_categories << product

      described_class.new(category).reindex!

      expect(ProductFilterValue.where(parameter: "f-colors", value_id: "10028")).to exist
    end
  end
end
