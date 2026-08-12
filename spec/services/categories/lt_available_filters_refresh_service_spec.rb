# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::LtAvailableFiltersRefreshService do
  describe "filter policy" do
    it "keeps all working IKEA filters, including firmness, seats and type" do
      category = Category.create!(ikea_id: "filter-policy-1", name: "Столы")
      service = described_class.new(category, reindex: false, ensure_series: false)

      raw = [
        { "parameter" => "f-colors", "name" => "Цвет", "values" => [{ "id" => "10028", "name" => "Белый" }] },
        { "parameter" => "f-material", "name" => "Материал", "values" => [{ "id" => "wood", "name" => "Дерево" }] },
        { "parameter" => "f-series", "name" => "Серия", "values" => [{ "id" => "LACK", "name" => "Серия LACK" }] },
        { "parameter" => "f-firmness", "name" => "Жесткость", "values" => [{ "id" => "firm", "name" => "Жесткий" }] },
        { "parameter" => "f-number-of-seats", "name" => "Количество мест", "values" => [{ "id" => "2", "name" => "2" }] },
        { "parameter" => "f-type", "name" => "Тип", "values" => [{ "id" => "table", "name" => "Стол" }] }
      ]

      filters = service.send(:merge_with_local_filters, service.send(:normalize_required_filters, raw))
      parameters = filters.map { |filter| filter["parameter"] }

      expect(parameters).to include(
        "f-series",
        "f-price-buckets",
        "f-material",
        "f-colors",
        "f-type",
        "f-firmness",
        "f-number-of-seats"
      )
      expect(filters.find { |f| f["parameter"] == "f-price-buckets" }["values"]).to eq([{ "id" => "PRICE_RANGE", "name" => "Цена" }])
    end

    it "does not hide a working shape filter for lighting categories" do
      lighting = Category.create!(ikea_id: "lighting-policy-1", name: "Освещение")
      furniture = Category.create!(ikea_id: "furniture-policy-1", name: "Столы")

      raw = [
        { "parameter" => "f-shape", "name" => "Форма", "values" => [{ "id" => "round", "name" => "Круглый" }] }
      ]

      lighting_service = described_class.new(lighting, reindex: false, ensure_series: false)
      furniture_service = described_class.new(furniture, reindex: false, ensure_series: false)

      lighting_filters = lighting_service.send(:normalize_required_filters, raw)
      furniture_filters = furniture_service.send(:normalize_required_filters, raw)

      expect(lighting_filters.map { |filter| filter["parameter"] }).to include("f-shape")
      expect(furniture_filters.map { |filter| filter["parameter"] }).to include("f-shape")
    end

    it "reads typed values and drops values with a zero upstream count" do
      category = Category.create!(ikea_id: "typed-filter-1", name: "Диваны")
      service = described_class.new(category, reindex: false, ensure_series: false)

      raw = [{
        "parameter" => "f-measurement-buckets",
        "name" => "Размер",
        "types" => [{
          "values" => [
            { "id" => "WIDTH_100_150", "name" => "100–149 см", "count" => 3 },
            { "id" => "WIDTH_150_200", "name" => "150–199 см", "count" => 0 }
          ]
        }]
      }]

      filters = service.send(:normalize_required_filters, raw)

      expect(filters.first["values"]).to eq([
        { "id" => "WIDTH_100_150", "name" => "100–149 см", "count" => 3 }
      ])
    end
  end

  describe "#call" do
    it "enqueues reindex when requested even if available_filters did not change" do
      category = Category.create!(
        ikea_id: "reindex-policy-1",
        name: "Столы",
        available_filters: [
          { "parameter" => "f-price-buckets", "name" => "Цена", "values" => [{ "id" => "PRICE_RANGE", "name" => "Цена" }] }
        ]
      )
      service = described_class.new(category, reindex: true, ensure_series: false)

      allow(service).to receive(:fetch_lt_filters).and_return([])
      expect(RefreshCategoryFilterIndexJob).to receive(:perform_later).with("reindex-policy-1")

      result = service.call

      expect(result.changed).to eq(false)
    end

    it "keeps existing filters when LT search returns HTTP 404" do
      category = Category.create!(
        ikea_id: "lt-missing-1",
        name: "Устаревший узел",
        available_filters: [
          { "parameter" => "f-colors", "name" => "Цвет", "values" => [{ "id" => "10028", "name" => "Белый" }] },
          { "parameter" => "f-price-buckets", "name" => "Цена", "values" => [{ "id" => "PRICE_RANGE", "name" => "Цена" }] }
        ]
      )
      service = described_class.new(category, reindex: false, ensure_series: false)
      response = double(success?: false, code: 404, message: "Not Found")

      allow(ProxyRotator).to receive(:with_proxy_retry).and_yield(nil)
      allow(HTTParty).to receive(:post).and_return(response)

      result = service.call

      expect(result.source).to eq("lt_missing")
      expect(result.changed).to eq(false)
      expect(category.reload.available_filters.map { |f| f["parameter"] }).to include("f-colors")
    end
  end
end
