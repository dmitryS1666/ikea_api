require 'rails_helper'

RSpec.describe Category, type: :model do
  describe "#display_filters_for_api" do
    let(:category) do
      create(
        :category,
        ikea_id: "cat-series-1",
        available_filters: [
          {
            "parameter" => "f-series",
            "name" => "Коллекции",
            "values" => [
              { "id" => "TOFTAN", "name" => "Серия TOFTAN" },
              { "id" => "EKOLN", "name" => "Серия EKOLN" }
            ]
          }
        ]
      )
    end

    it "counts only products with available stock" do
      in_stock = create(:product, category_id: category.ikea_id, quantity: 5)
      out_of_stock = create(:product, category_id: category.ikea_id, quantity: 0)

      create(:product_filter_value, product: in_stock, category_id: category.ikea_id, parameter: "f-series", value_id: "TOFTAN")
      create(:product_filter_value, product: out_of_stock, category_id: category.ikea_id, parameter: "f-series", value_id: "TOFTAN")

      filters = category.display_filters_for_api
      series_filter = filters.find { |f| f["parameter"] == "f-series" }
      toftan = series_filter["values"].find { |v| v["id"] == "TOFTAN" }

      expect(toftan["count"]).to eq(1)
    end

    it "hides series values that have no in-stock products" do
      out_of_stock = create(:product, category_id: category.ikea_id, quantity: 0)
      create(:product_filter_value, product: out_of_stock, category_id: category.ikea_id, parameter: "f-series", value_id: "EKOLN")

      filters = category.display_filters_for_api
      series_filter = filters.find { |f| f["parameter"] == "f-series" }
      expect(series_filter).to be_nil
    end

    it "aggregates series counts from in-stock products indexed under descendant categories" do
      parent = create(
        :category,
        ikea_id: "parent-tree-1",
        available_filters: [
          {
            "parameter" => "f-series",
            "name" => "Коллекции",
            "values" => [
              { "id" => "TOFTAN", "name" => "Серия TOFTAN" }
            ]
          }
        ]
      )
      create(
        :category,
        ikea_id: "child-tree-1",
        parent_ids: ["parent-tree-1"],
        available_filters: []
      )

      product = create(:product, category_id: "child-tree-1", quantity: 5)
      create(:product_filter_value, product: product, category_id: "child-tree-1", parameter: "f-series", value_id: "TOFTAN")

      filters = parent.display_filters_for_api
      series_filter = filters.find { |f| f["parameter"] == "f-series" }
      toftan = series_filter["values"].find { |v| v["id"] == "TOFTAN" }

      expect(toftan["count"]).to eq(1)
    end
  end
end
