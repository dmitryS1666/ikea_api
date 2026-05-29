# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::QueryScope do
  before do
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(instance_double(ExchangeRate, rate_per_unit: 1.0))
    allow(CalculatorSetting).to receive(:get).and_return(1.0)
  end

  describe "#call" do
    it "matches products with singular stem when query is plural (шкафы → шкаф)" do
      product = create(
        :product,
        sku: "WARD-001",
        name: "PAKS",
        name_ru: "ПАКС",
        small_desc_name: "Шкаф, белый",
        price: 100,
        quantity: 5
      )

      scope = described_class.new("шкафы").call
      expect(scope).to contain_exactly(product)
    end

    it "includes in-stock products from categories matching the query" do
      category = create(
        :category,
        ikea_id: "cat-wardrobe",
        unique_id: 90_100,
        parent_ids: [],
        translated_name: "Шкафы PAX",
        name: "PAX wardrobes"
      )
      in_category = create(
        :product,
        sku: "PAX-001",
        name: "PAX frame",
        name_ru: "Каркас",
        small_desc_name: "Каркас, белый",
        price: 200,
        quantity: 5,
        category_id: category.ikea_id
      )
      create(
        :product,
        sku: "OTHER-001",
        name: "Table",
        name_ru: "Стол",
        small_desc_name: "Стол",
        price: 50,
        quantity: 5
      )

      scope = described_class.new("шкафы").call
      expect(scope).to include(in_category)
    end
  end
end
