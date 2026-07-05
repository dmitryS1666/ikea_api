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

    it "narrows multi-word queries using intersection semantics" do
      both_terms = create(
        :product,
        sku: "KALLAX-AND-001",
        name: "KALLAX",
        name_ru: "KALLAX",
        small_desc_name: "Стеллаж 4 секции",
        price: 200,
        quantity: 5
      )
      only_brand = create(
        :product,
        sku: "KALLAX-ONLY-001",
        name: "KALLAX",
        name_ru: "KALLAX",
        small_desc_name: "Коробка для хранения",
        price: 120,
        quantity: 5
      )
      only_type = create(
        :product,
        sku: "TYPE-ONLY-001",
        name: "BESTA",
        name_ru: "БЕСТО",
        small_desc_name: "Стеллаж, белый",
        price: 140,
        quantity: 5
      )

      scope = described_class.new("Kallax стеллаж").call

      expect(scope).to contain_exactly(both_terms)
      expect(scope).not_to include(only_brand, only_type)
    end
  end

  describe "#apply_default_order" do
    it "prioritizes both words in name over description and mixed matches" do
      in_name = create(
        :product,
        sku: "RANK-NAME-001",
        name: "Kallax стеллаж",
        name_ru: "Kallax стеллаж",
        small_desc_name: "Белый",
        price: 200,
        quantity: 5
      )
      in_desc = create(
        :product,
        sku: "RANK-DESC-001",
        name: "Storage item",
        name_ru: "Модуль",
        small_desc_name: "Kallax стеллаж, белый",
        price: 180,
        quantity: 5
      )
      mixed = create(
        :product,
        sku: "RANK-MIXED-001",
        name: "Kallax",
        name_ru: "Kallax",
        small_desc_name: "Стеллаж 8 секций",
        price: 160,
        quantity: 5
      )

      scope = Product.with_available_stock.where(id: [mixed.id, in_desc.id, in_name.id])
      ordered_ids = described_class.new("Kallax стеллаж").apply_default_order(scope).pluck(:id)

      expect(ordered_ids).to eq([in_name.id, in_desc.id, mixed.id])
    end
  end
end
