# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::FiltersAggregator do
  let!(:category) do
    create(
      :category,
      ikea_id: "filter-cat-1",
      unique_id: 91_001,
      parent_ids: [],
      name: "Shkafy",
      translated_name: "Шкафы",
      available_filters: [
        {
          "parameter" => "f-color",
          "name" => "Цвет",
          "values" => [
            { "id" => "white", "name" => "Белый" },
            { "id" => "black", "name" => "Чёрный" }
          ]
        }
      ]
    )
  end

  let!(:product) do
    create(
      :product,
      sku: "00568144",
      name: "PAKS",
      name_ru: "ПАКС",
      small_desc_name: "Шкаф, белый",
      price: 100,
      quantity: 5,
      category_id: category.ikea_id
    )
  end

  before do
    create(
      :product_filter_value,
      product: product,
      category_id: category.ikea_id,
      parameter: "f-color",
      value_id: "white"
    )
  end

  it "aggregates filter counts for a text search scope" do
    scope = Search::QueryScope.new("00568144").call
    result = described_class.new(scope, [category]).call

    color = result.find { |filter| filter["parameter"] == "f-color" }
    expect(color).to be_present
    expect(color["values"]).to contain_exactly(
      hash_including("id" => "white", "count" => 1)
    )
  end

  it "queries filter values by materialized product ids, not a nested search subquery" do
    scope = Search::QueryScope.new("00568144").call

    allow(ProductFilterValue).to receive(:where).and_call_original

    described_class.new(scope, [category]).call

    expect(ProductFilterValue).to have_received(:where).with(product_id: [product.id])
  end
end
