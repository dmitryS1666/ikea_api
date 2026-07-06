# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Products API stock filtering", type: :request do
  describe "GET /api/v1/products/:sku" do
    it "returns 404 when product is out of stock" do
      product = create(:product, sku: "s99999999", quantity: 0)

      get "/api/v1/products/#{product.sku}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["code"]).to eq("product_unavailable")
      expect(response.parsed_body["issue_reason"]).to eq("discontinued")
      expect(response.parsed_body["similar_products"]).to be_an(Array)
    end

    it "returns product when in stock" do
      product = create(:product, sku: "s88888888", quantity: 2)

      get "/api/v1/products/#{product.sku}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "attributes", "sku")).to eq(product.sku)
    end

    it "returns 404 with not_found reason for unknown sku" do
      get "/api/v1/products/NON_EXISTING_SKU"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["code"]).to eq("product_not_found")
      expect(response.parsed_body["issue_reason"]).to eq("not_found")
      expect(response.parsed_body["similar_products"]).to eq([])
    end
  end

  describe "GET /api/v1/products" do
    it "excludes out-of-stock products" do
      in_stock = create(:product, sku: "s77777777", quantity: 1)
      create(:product, sku: "s66666666", quantity: 0)

      get "/api/v1/products", params: { per_page: 100 }

      skus = response.parsed_body["data"].map { |row| row.dig("attributes", "sku") }
      expect(skus).to include(in_stock.sku)
      expect(skus).not_to include("s66666666")
    end
  end
end
