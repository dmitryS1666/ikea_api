# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::RebuildFseriesAvailableFiltersService do
  it "builds deduplicated f-series without Серия prefix and propagates to tree" do
    parent = create(
      :category,
      ikea_id: "fseries-parent",
      available_filters: [
        {
          "parameter" => "f-series",
          "name" => "Серия",
          "values" => [
            { "id" => "700598", "name" => "Серия TRÅDFRI" }
          ]
        },
        { "parameter" => "f-colors", "values" => [{ "id" => "1", "name" => "biały" }] }
      ]
    )
    child = create(
      :category,
      ikea_id: "fseries-child",
      parent_ids: ["fseries-parent"],
      available_filters: []
    )

    product = create(
      :product,
      collection: "KAJPLATS",
      name_ru: "Лампа KAJPLATS smart",
      quantity: 5,
      full_attributes: { "Seria" => "Серия KAJPLATS" }
    )
    child.products_through_categories << product

    result = described_class.new(parent, propagate_to_descendants: true).call
    expect(result.changed).to eq(true)
    expect(result.series_count).to be >= 2

    parent.reload
    series = parent.available_filters.find { |f| f["parameter"] == "f-series" }
    names = series["values"].map { |v| v["name"] }
    ids = series["values"].map { |v| v["id"] }

    expect(names).to include("KAJPLATS")
    expect(names.map { |n| Products::SeriesFilterNormalization.normalize_key(n) }).to include("TRADFRI")
    expect(names.none? { |n| n.include?("[") }).to eq(true)
    expect(ids.none? { |id| id.to_s.start_with?("[") }).to eq(true)
    expect(names.none? { |n| n.match?(/\AСерия\s/i) }).to eq(true)
    expect(ids).to include("700598")
    expect(parent.available_filters.find { |f| f["parameter"] == "f-colors" }).to be_present

    child.reload
    child_series = child.available_filters.find { |f| f["parameter"] == "f-series" }
    expect(child_series["values"].map { |v| v["name"] }).to include("KAJPLATS")
  end
end
