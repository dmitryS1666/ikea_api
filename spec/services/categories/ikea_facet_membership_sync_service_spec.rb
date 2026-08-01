# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::IkeaFacetMembershipSyncService do
  describe "IKEA request encoding" do
    let(:category) { create(:category, ikea_id: "57542") }
    let(:service) { described_class.new(category) }

    it "encodes boolean facet values as JSON booleans" do
      config = service.send(:request_body, "f-home-smart", "true", 0)
        .dig(:components, 0, :filterConfig)

      expect(config["f-home-smart"]).to eq(true)
    end

    it "keeps regular facet values in an array" do
      config = service.send(:request_body, "f-colors", "10028", 0)
        .dig(:components, 0, :filterConfig)

      expect(config["f-colors"]).to eq(["10028"])
    end
  end

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
    expect(result.errors).to eq([])
  end

  it "keeps old rows for a failed facet value and synchronizes successful values" do
    category = create(
      :category,
      ikea_id: "57542",
      available_filters: [{
        "parameter" => "f-home-smart",
        "name" => "Умный дом",
        "values" => [
          { "id" => "true", "name" => "Да", "count" => 1 },
          { "id" => "compatible", "name" => "Совместимо", "count" => 1 }
        ]
      }]
    )
    old_product = create(:product, sku: "40497395")
    new_product = create(:product, sku: "70594601")
    ProductFilterValue.create!(
      product: old_product,
      category: category,
      parameter: "f-home-smart",
      value_id: "true"
    )

    service = described_class.new(category)
    allow(service).to receive(:search).with("f-home-smart", "true", 0)
      .and_raise("IKEA facet request failed category=57542 f-home-smart=true: HTTP 400")
    allow(service).to receive(:search).with("f-home-smart", "compatible", 0).and_return(
      "results" => [{
        "items" => [{
          "type" => "PRODUCT",
          "product" => { "id" => new_product.sku, "itemNoGlobal" => new_product.sku }
        }]
      }]
    )

    result = service.call

    expect(result.errors).to contain_exactly(include(
      "parameter" => "f-home-smart",
      "value_id" => "true",
      "message" => include("HTTP 400")
    ))
    expect(
      ProductFilterValue
        .where(category_id: category.ikea_id, parameter: "f-home-smart")
        .pluck(:product_id, :value_id)
    ).to contain_exactly(
      [old_product.id, "true"],
      [new_product.id, "compatible"]
    )
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

  it "reports one canonical unmatched SKU when IKEA returns prefixed and global identifiers" do
    category = create(
      :category,
      ikea_id: "50003",
      available_filters: [{
        "parameter" => "f-series",
        "name" => "Серия",
        "values" => [{ "id" => "54968", "name" => "UPPDATERA", "count" => 1 }]
      }]
    )
    service = described_class.new(category)
    allow(service).to receive(:search).with("f-series", "54968", 0).and_return(
      "results" => [{
        "items" => [{
          "type" => "PRODUCT",
          "product" => {
            "id" => "s09308825",
            "itemNoGlobal" => "09308825",
            "itemNo" => "s09308825"
          }
        }]
      }]
    )

    result = service.call

    expect(result.unmatched_skus).to eq(["09308825"])
    expect(result.memberships_count).to eq(0)
  end
end
