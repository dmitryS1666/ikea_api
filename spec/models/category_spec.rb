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

    it "dedupes f-series synonyms into one row with correct distinct product count" do
      category = create(
        :category,
        ikea_id: "cat-series-dedupe",
        available_filters: [
          {
            "parameter" => "f-series",
            "name" => "Коллекции",
            "values" => [
              { "id" => "FJALLBO_LONG", "name" => "Серия FJÄLLBO" },
              { "id" => "FJALLBO_SHORT", "name" => "FJÄLLBO" }
            ]
          }
        ]
      )

      product = create(:product, category_id: category.ikea_id, quantity: 5)
      create(:product_filter_value, product: product, category_id: category.ikea_id, parameter: "f-series", value_id: "FJALLBO_LONG")
      create(:product_filter_value, product: product, category_id: category.ikea_id, parameter: "f-series", value_id: "FJALLBO_SHORT")

      filters = category.display_filters_for_api
      series_filter = filters.find { |f| f["parameter"] == "f-series" }
      expect(series_filter["values"].size).to eq(1)
      expect(series_filter["values"].first["count"]).to eq(1)
      expect(series_filter["values"].first["id"]).to eq("FJALLBO_SHORT")
    end
  end

  describe "#catalog_url" do
    it "returns a slug-based path for a root category" do
      category = create(:category, ikea_id: "root-1", name: "Мебель", parent_ids: [])
      category.update_column(:cached_slug, "mebel")

      expect(category.catalog_url).to eq("/catalog/mebel/")
    end

    it "includes ancestor slugs for nested categories" do
      parent = create(:category, ikea_id: "parent-1", name: "Хранение", parent_ids: [])
      parent.update_column(:cached_slug, "mebel-dlya-hraneniya")

      child = create(
        :category,
        ikea_id: "child-1",
        name: "Встроенные шкафы",
        parent_ids: [parent.ikea_id]
      )
      child.update_column(:cached_slug, "vstroennye-shkafy")

      expect(child.catalog_url).to eq("/catalog/mebel-dlya-hraneniya/vstroennye-shkafy/")
    end
  end

  describe ".popular" do
    it "orders popular categories by popular_position" do
      second = create(:category, ikea_id: "popular-second", name: "B", translated_name: "B", is_popular: true, popular_position: 20)
      first = create(:category, ikea_id: "popular-first", name: "A", translated_name: "A", is_popular: true, popular_position: 10)
      create(:category, ikea_id: "not-popular", name: "C", translated_name: "C", is_popular: false, popular_position: 1)

      expect(Category.popular.pluck(:ikea_id)).to eq([first.ikea_id, second.ikea_id])
    end
  end

end
