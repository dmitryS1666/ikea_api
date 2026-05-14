# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::WeightExtractor do
  describe ".extract_packaging_kg" do
    it "reads packaging.details only" do
      src = {
        "size" => {
          "Общий вес" => "99 кг",
          "packaging" => {
            "details" => [{ "weight" => "1.07 кг", "count" => 1 }]
          }
        }
      }
      expect(described_class.extract_packaging_kg(src)).to eq(1.07)
    end

    it "returns nil when only total weight exists" do
      src = { "size" => { "Общий вес" => "2 кг" } }
      expect(described_class.extract_packaging_kg(src)).to be_nil
    end
  end
end
