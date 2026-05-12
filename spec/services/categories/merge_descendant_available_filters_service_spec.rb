# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::MergeDescendantAvailableFiltersService do
  it "merges f-series value ids from descendants into parent available_filters" do
    parent = create(
      :category,
      ikea_id: "merge-parent-1",
      available_filters: [
        {
          "parameter" => "f-series",
          "name" => "Коллекции",
          "values" => [
            { "id" => "A", "name" => "A" }
          ]
        }
      ]
    )
    create(
      :category,
      ikea_id: "merge-child-1",
      parent_ids: ["merge-parent-1"],
      available_filters: [
        {
          "parameter" => "f-series",
          "name" => "Серии",
          "values" => [
            { "id" => "B", "name" => "B" }
          ]
        }
      ]
    )

    result = described_class.new(parent).call
    expect(result.merge_changed).to eq(true)

    parent.reload
    series = parent.available_filters.find { |f| f["parameter"] == "f-series" }
    ids = series["values"].map { |v| v["id"] }
    expect(ids).to contain_exactly("A", "B")
  end

  it "returns merge_changed false when there are no descendants" do
    cat = create(:category, ikea_id: "leaf-1", available_filters: [])
    result = described_class.new(cat).call
    expect(result.merge_changed).to eq(false)
    expect(result.reason).to eq(:no_descendants)
  end
end
