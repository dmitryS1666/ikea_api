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

    it "reindexes only listed parameters and leaves others unchanged" do
      category = create(:category, ikea_id: "700888", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [
            { "id" => "PRICE_19900_19901", "name" => "199 zl" }
          ]
        },
        {
          "parameter" => "f-colors",
          "values" => [
            { "id" => "10028", "name" => "szary" }
          ]
        }
      ])

      product = create(:product,
                       price: 199,
                       full_attributes: { "Kolor" => "Szary" })

      category.products_through_categories << product

      described_class.new(category).reindex!

      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-price-buckets")).to exist
      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-colors")).to exist

      described_class.new(category, parameters: %w[f-colors]).reindex!

      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-colors", value_id: "10028")).to exist
      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-price-buckets", value_id: "PRICE_19900_19901")).to exist
    end
  end

  describe "#reindex_product" do
    it "updates only selected parameters for one product" do
      category = create(:category, ikea_id: "700777", available_filters: [
        {
          "parameter" => "f-price-buckets",
          "values" => [
            { "id" => "PRICE_19900_19901", "name" => "199 zl" }
          ]
        },
        {
          "parameter" => "f-colors",
          "values" => [
            { "id" => "10028", "name" => "szary" }
          ]
        }
      ])

      product = create(:product,
                       price: 199,
                       full_attributes: { "Kolor" => "Szary" })

      category.products_through_categories << product

      described_class.new(category).reindex_product(product)

      described_class.new(category, parameters: %w[f-colors]).reindex_product(product)

      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-colors")).to exist
      expect(ProductFilterValue.where(product_id: product.id, parameter: "f-price-buckets")).to exist
    end
  end

  describe "f-series indexing" do
    it "stores one value_id per logical series when available_filters lists synonyms" do
      category = create(:category, ikea_id: "700601", available_filters: [
        {
          "parameter" => "f-series",
          "values" => [
            { "id" => "id_guest", "name" => "Серия для гостиных HAUGA" },
            { "id" => "id_short", "name" => "HAUGA" },
            { "id" => "id_table", "name" => "Серия для столовых HAUGA" }
          ]
        }
      ])

      product = create(:product, name_ru: "Комод HAUGA белый", quantity: 1)
      category.products_through_categories << product

      described_class.new(category).reindex!

      rows = ProductFilterValue.where(product_id: product.id, category_id: category.ikea_id, parameter: "f-series")
      expect(rows.pluck(:value_id)).to eq(["id_short"])
    end
  end
end
