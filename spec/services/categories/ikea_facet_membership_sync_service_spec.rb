# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::IkeaFacetMembershipSyncService do
  it "replaces heuristic upstream rows with exact IKEA facet memberships and preserves local rows" do
    category = create(
      :category,
      ikea_id: "20515",
      available_filters: [
        {
          "parameter" => "f-colors",
          "name" => "Цвет",
          "values" => [
            { "id" => "10028", "name" => "Серый", "count" => 1 },
            { "id" => "10029", "name" => "Белый", "count" => 0 }
          ]
        },
        {
          "parameter" => "f-price-buckets",
          "name" => "Цена",
          "values" => [{ "id" => "PRICE_RANGE", "name" => "Цена" }]
        }
      ]
    )
    product = create(:product, sku: "40573285")
    stale_product = create(:product, sku: "99999999")

    ProductFilterValue.create!(
      product: stale_product,
      category: category,
      parameter: "f-colors",
      value_id: "old"
    )
    ProductFilterValue.create!(
      product: product,
      category: category,
      parameter: "f-price-buckets",
      value_id: "PRICE_RANGE"
    )

    service = described_class.new(category)
    allow(service).to receive(:search).with("f-colors", "10028", 0).and_return(
      "results" => [{
        "items" => [{
          "type" => "PRODUCT",
          "product" => { "id" => "40573285", "itemNoGlobal" => "40573285" }
        }]
      }]
    )

    result = service.call

    expect(result.memberships_count).to eq(1)
    expect(result.values_count).to eq(1)
    expect(
      ProductFilterValue.where(category_id: category.ikea_id, parameter: "f-colors").pluck(:product_id, :value_id)
    ).to eq([[product.id, "10028"]])
    expect(
      ProductFilterValue.where(category_id: category.ikea_id, parameter: "f-price-buckets").pluck(:value_id)
    ).to eq(["PRICE_RANGE"])
  end

  it "does not erase existing rows when there are no working upstream facets" do
    category = create(
      :category,
      ikea_id: "20516",
      available_filters: [{
        "parameter" => "f-colors",
        "name" => "Цвет",
        "values" => [{ "id" => "10028", "name" => "Серый", "count" => 0 }]
      }]
    )
    product = create(:product)
    row = ProductFilterValue.create!(
      product: product,
      category: category,
      parameter: "f-colors",
      value_id: "existing"
    )

    expect { described_class.new(category).call }
      .to raise_error(/no working facets/)
    expect(ProductFilterValue.exists?(row.id)).to eq(true)
  end
end
