# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Search", type: :request do
  describe "GET /api/v1/search/suggest" do
    let!(:category) do
      create(
        :category,
        ikea_id: "search-cat-1",
        unique_id: 90_001,
        parent_ids: [],
        name: "Shkafy",
        translated_name: "Шкафы",
        cached_slug: "shkafy",
        available_filters: [
          {
            "parameter" => "f-color",
            "name" => "Цвет",
            "values" => [
              { "id" => "white", "name" => "Белый" },
              { "id" => "black", "name" => "Чёрный" }
            ]
          }
        ]
      )
    end

    let!(:product) do
      create(
        :product,
        sku: "12345678",
        name: "PAKS",
        name_ru: "ПАКС Шкаф",
        small_desc_name: "Шкаф, белый",
        price: 100,
        quantity: 5,
        category_id: category.ikea_id,
        cached_slug: "shkaf-paks"
      )
    end

    before do
      allow(ExchangeRate).to receive(:fetch_or_create).and_return(instance_double(ExchangeRate, rate_per_unit: 1.0))
      allow(CalculatorSetting).to receive(:get).and_return(1.0)
      allow(Seo::BreadcrumbsBuilder).to receive(:for_product).and_return([{ title: "Шкафы", url: "/catalog/shkafy/" }])
    end

    it "returns contract-shaped JSON on first page" do
      get "/api/v1/search/suggest", params: { q: "шкаф" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body).to include("suggestions", "categories", "products", "available_filters", "meta")
      expect(body["categories"]).to include("data")
      expect(body["products"]).to include("data")
      expect(body["meta"]).to include("total", "total_pages", "page", "per_page")

      category_attrs = body.dig("categories", "data", 0, "attributes")
      expect(category_attrs).to include("slug", "translated_name", "name")

      product_attrs = body.dig("products", "data", 0, "attributes")
      expect(product_attrs).to include("sku", "slug", "name_ru", "price_byn", "local_images", "images", "breadcrumbs")
    end

    it "filters products by min_price in BYN" do
      cheap = create(:product, sku: "cheap-1", name: "Cheap шкаф", price: 10, quantity: 5, category_id: category.ikea_id)
      expensive = create(:product, sku: "exp-1", name: "Premium шкаф", price: 500, quantity: 5, category_id: category.ikea_id)

      threshold = PriceCalculationService.product_storefront_price_byn(
        cheap.price.to_f,
        weight_kg: cheap.packaging_weight_kg.to_f,
        delivery_pln: cheap.delivery_cost.to_f,
        pln_rate: 1.0,
        buffer: 1.0
      ) + 0.01

      get "/api/v1/search/suggest", params: { q: "шкаф", min_price: threshold }

      skus = JSON.parse(response.body).dig("products", "data").map { |row| row.dig("attributes", "sku") }
      expect(skus).to include(expensive.sku.sub(/\As/i, ""))
      expect(skus).not_to include(cheap.sku.sub(/\As/i, ""))
    end

    it "filters products by attribute filters" do
      create(:product_filter_value,
             product: product,
             category_id: category.ikea_id,
             parameter: "f-color",
             value_id: "white")

      other = create(:product, sku: "other-shkaf", name: "Other шкаф", price: 50, quantity: 5, category_id: category.ikea_id)
      create(:product_filter_value,
             product: other,
             category_id: category.ikea_id,
             parameter: "f-color",
             value_id: "black")

      get "/api/v1/search/suggest", params: { q: "шкаф", "filters[f-color][]": "white" }

      skus = JSON.parse(response.body).dig("products", "data").map { |row| row.dig("attributes", "sku") }
      expect(skus).to include(product.sku.sub(/\As/i, ""))
      expect(skus).not_to include(other.sku.sub(/\As/i, ""))
    end

    it "omits suggestions and categories on page 2" do
      get "/api/v1/search/suggest", params: { q: "шкаф", page: 2, per_page: 1 }

      body = JSON.parse(response.body)
      expect(body["suggestions"]).to eq([])
      expect(body["categories"]["data"]).to eq([])
      expect(body["available_filters"]).to eq([])
    end
  end
end
