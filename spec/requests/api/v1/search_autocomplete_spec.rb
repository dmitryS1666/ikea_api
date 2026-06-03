# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Search autocomplete", type: :request do
  describe "GET /api/v1/search/autocomplete" do
    let!(:category) do
      create(
        :category,
        ikea_id: "autocomplete-cat-1",
        unique_id: 91_001,
        parent_ids: [],
        name: "Wardrobes",
        translated_name: "Гардеробы",
        cached_slug: "garderoby"
      )
    end

    let!(:product) do
      create(
        :product,
        sku: "s39491276",
        name: "PAX",
        name_ru: "PAX",
        small_desc_name: "Гардероб, комбинация, белый",
        price: 100,
        quantity: 5,
        category_id: category.ikea_id,
        cached_slug: "pax"
      )
    end

    it "returns light flat dropdown contract" do
      get "/api/v1/search/autocomplete", params: { q: "шкафы" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body).to include("query", "normalized_query", "suggestions", "categories", "products")
      expect(body).not_to include("available_filters", "meta", "popular_queries")
      expect(body["suggestions"].first).to include("title", "query")
      expect(body["categories"].first).to include("id", "title", "slug", "url")
      expect(body["products"].first).to include(
        "sku",
        "slug",
        "url",
        "name_ru",
        "small_desc_name",
        "title",
        "category_title",
        "category_url",
        "preview_image"
      )
    end

    it "finds PAX/wardrobe products by the user query шкафы" do
      get "/api/v1/search/autocomplete", params: { q: "шкафы" }

      body = JSON.parse(response.body)
      product_titles = body["products"].map { |row| row["title"] }
      category_titles = body["categories"].map { |row| row["title"] }
      suggestion_titles = body["suggestions"].map { |row| row["title"] }

      expect(product_titles).to include("PAX Гардероб, комбинация, белый")
      expect(category_titles).to include("Гардеробы")
      expect(suggestion_titles).to include("Шкафы")
    end

    it "does not run heavy search for too short query" do
      get "/api/v1/search/autocomplete", params: { q: "ш" }

      body = JSON.parse(response.body)
      expect(body["suggestions"]).to eq([])
      expect(body["categories"]).to eq([])
      expect(body["products"]).to eq([])
    end
  end
end
