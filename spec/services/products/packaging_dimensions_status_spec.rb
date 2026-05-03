# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::PackagingDimensionsStatus do
  describe ".size_has_full_packaging_dimensions?" do
    it "returns true when packaging.details has width, height, length" do
      size = {
        "packaging" => {
          "desc" => "x",
          "details" => [{ "width" => "10 см", "height" => "20 см", "length" => "30 см" }]
        },
        "packages" => []
      }
      expect(described_class.size_has_full_packaging_dimensions?(size)).to eq(true)
    end

    it "returns true when packages have Ширина, Высота, Глубина" do
      size = {
        "packaging" => { "desc" => nil, "details" => [] },
        "packages" => [
          {
            "measurements" => [
              { "name" => "Ширина", "measure" => "40 см" },
              { "name" => "Высота", "measure" => "88 см" },
              { "name" => "Глубина", "measure" => "39 см" }
            ]
          }
        ]
      }
      expect(described_class.size_has_full_packaging_dimensions?(size)).to eq(true)
    end

    it "returns false when details and packages lack a full box" do
      size = {
        "packaging" => { "desc" => "HEMNES, 403.717.63", "details" => [] },
        "packages" => []
      }
      expect(described_class.size_has_full_packaging_dimensions?(size)).to eq(false)
    end
  end
end
