# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::SuggestCategoryResolver do
  let!(:parent) do
    Category.create!(
      ikea_id: "700640",
      name: "Sofy i fotele",
      translated_name: "Диваны и кресла",
      parent_ids: []
    )
  end

  let!(:child) do
    Category.create!(
      ikea_id: "fu003",
      name: "Sofy nierozkładane",
      translated_name: "Диваны нераскладные",
      parent_ids: [parent.ikea_id]
    )
  end

  let!(:product) do
    Product.create!(
      sku: "SEARCH-SPEC-001",
      name: "Test sofa",
      name_ru: "Нераскладной диван серый",
      price: 100,
      quantity: 5,
      category_id: parent.ikea_id
    )
  end

  before do
    CategoryProduct.create!(product: product, category_id: child.ikea_id)
  end

  describe "#call" do
    it "returns the subcategory as a flat root entry for a matching query" do
      scope = Product.where(id: product.id)
      result = described_class.new("нераскладные", products: [product], products_scope: scope).call

      names = result.map { |row| row[:translated_name] }
      ids = result.map { |row| row[:id].to_s }

      expect(ids).to include("fu003")
      expect(names).to include("Диваны нераскладные")
      expect(result.find { |row| row[:id].to_s == "fu003" }[:children]).to eq([])
    end

    it "does not return the parent when a matching child category exists" do
      scope = Product.where(id: product.id)
      result = described_class.new("нераскладные", products: [product], products_scope: scope).call

      expect(result.map { |row| row[:id].to_s }).not_to include("700640")
    end

    it "matches categories by filter json text" do
      parent.update!(available_filters: [{ "name" => "Нераскладные", "parameter" => "f-type", "values" => [] }])

      result = described_class.new("нераскладные").call
      expect(result.map { |row| row[:id].to_s }).to include(parent.ikea_id.to_s)
    end
  end
end
