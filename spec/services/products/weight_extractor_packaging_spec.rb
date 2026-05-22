# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::WeightExtractor do
  describe ".extract_packaging_kg" do
    it "суммирует веса всех строк packaging.details (вес × count)" do
      src = {
        "size" => {
          "Общий вес" => "99 кг",
          "packaging" => {
            "details" => [
              { "weight" => "10 кг", "count" => 2 },
              { "weight" => "5 кг", "count" => 1 }
            ]
          }
        }
      }
      expect(described_class.extract_packaging_kg(src)).to eq(25.0)
    end

    it "суммирует веса всех packages[].measurements" do
      src = {
        "size" => {
          "Общий вес" => "99 кг",
          "packages" => [
            { "measurements" => [{ "name" => "Вес", "measure" => "20 кг" }, { "name" => "Упаковка(-и)", "measure" => "1" }] },
            { "measurements" => [{ "name" => "Вес", "measure" => "15.5 кг" }] }
          ]
        }
      }
      expect(described_class.extract_packaging_kg(src)).to eq(35.5)
    end

    it "предпочитает packages, если в них есть вес (без двойного учёта details)" do
      src = {
        "size" => {
          "packaging" => {
            "details" => [{ "weight" => "1 кг", "count" => 1 }]
          },
          "packages" => [
            { "measurements" => [{ "name" => "Вес", "measure" => "44.4 кг" }] }
          ]
        }
      }
      expect(described_class.extract_packaging_kg(src)).to eq(44.4)
    end

    it "не использует «Общий вес», если нет элементов упаковки" do
      src = { "size" => { "Общий вес" => "2 кг" } }
      expect(described_class.extract_packaging_kg(src)).to be_nil
    end
  end

  describe ".packaging_weight_kg_for_product" do
    it "считает сумму по packaging.details из customer payload" do
      product = create(
        :product,
        weight: nil,
        full_attributes: {
          "dimensions_map" => {
            "packaging" => {
              "details" => [
                { "weight" => "12 кг", "count" => 1, "width" => "10 см", "height" => "10 см", "length" => "10 см" },
                { "weight" => "8 кг", "count" => 1, "width" => "20 см", "height" => "20 см", "length" => "20 см" }
              ]
            }
          }
        }
      )

      expect(described_class.packaging_weight_kg_for_product(product)).to eq(20.0)
    end
  end

  describe ".packaging_weight_kg_for_product_fast" do
    it "совпадает с packaging_weight_kg_for_product (customer payload, не сырой jsonb)" do
      product = create(
        :product,
        weight: nil,
        full_attributes: {
          "dimensions_map" => {
            "packaging" => {
              "details" => [
                { "weight" => "12 кг", "count" => 1 },
                { "weight" => "8 кг", "count" => 1 }
              ]
            }
          }
        }
      )

      expect(described_class.packaging_weight_kg_for_product_fast(product)).to eq(20.0)
      expect(described_class.packaging_weight_kg_for_product_fast(product))
        .to eq(described_class.packaging_weight_kg_for_product(product))
    end
  end
end
