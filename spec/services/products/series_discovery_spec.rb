# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::SeriesDiscovery do
  describe ".raw_labels_from_product" do
    it "reads collection and Seria attribute" do
      product = build(
        :product,
        collection: "KAJPLATS",
        name_ru: "Лампа",
        full_attributes: { "Seria" => "Серия KAJPLATS" }
      )

      labels = described_class.raw_labels_from_product(product)
      expect(labels).to include("KAJPLATS", "Серия KAJPLATS")
    end

    it "extracts series token from product title" do
      product = build(:product, name_ru: "Лента LED SKYDRAG белая", collection: nil, full_attributes: {})

      labels = described_class.raw_labels_from_product(product)
      expect(labels).to include("SKYDRAG")
    end
  end
end
