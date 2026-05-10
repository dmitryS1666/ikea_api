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

  describe ".modal_has_full_packaging_dimensions?" do
    it "returns true when modal packages include width, height, depth" do
      mm = {
        "packages" => [
          {
            "measurements" => [
              { "name" => "Szerokość", "measure" => "40 cm" },
              { "name" => "Wysokość", "measure" => "88 cm" },
              { "name" => "Głębokość", "measure" => "39 cm" }
            ]
          }
        ]
      }
      expect(described_class.modal_has_full_packaging_dimensions?(mm)).to eq(true)
    end

    it "returns false when packages lack a full box" do
      mm = {
        "packages" => [
          {
            "measurements" => [
              { "name" => "Waga", "measure" => "12 kg" }
            ]
          }
        ]
      }
      expect(described_class.modal_has_full_packaging_dimensions?(mm)).to eq(false)
    end
  end
end
