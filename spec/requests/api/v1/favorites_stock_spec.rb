# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Favorites API stock", type: :request do
  describe "POST /api/v1/favorites" do
    it "adds a product with zero quantity" do
      product = create(:product, sku: "s55555555", quantity: 0)

      post "/api/v1/favorites", params: { sku: product.sku }

      expect(response).to have_http_status(:ok)
      item = response.parsed_body.dig("favorite", "items")&.find { |row| row["sku"] == "55555555" }
      expect(item).to be_present
      expect(item.dig("product", "quantity")).to eq(0)
    end

    it "rejects an unknown sku" do
      post "/api/v1/favorites", params: { sku: "NON_EXISTING_SKU" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
