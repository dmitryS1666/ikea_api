require "rails_helper"

RSpec.describe "Delivery Europost offices", type: :request do
  describe "GET /api/v1/delivery/europost_offices" do
    before do
      allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.0))
      allow(PriceCalculationService).to receive(:exchange_rate_buffer).and_return(1.0)
    end

    it "keeps old behavior without cart_id" do
      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "123", "WarehouseName" => "EP-1", "Address7Name" => "Минск", "Latitude" => "53.9", "Longitude" => "27.5" }]
      )

      get "/api/v1/delivery/europost_offices"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"]).to be_an(Array)
      expect(body["offices"].first["provider"]).to eq("europost")
      expect(body["offices"].first).to have_key("external_id")
    end

    it "filters out non-eligible pickup points when cart_id is provided" do
      cart = create(:cart)
      # `package_volume` is stored in liters.
      # We want the "bad" pickup point (max_volume_m3 = 0.019) to fail by volume (not by weight),
      # therefore:
      # - weight < max_weight_kg (9.9) => e.g. 9.0
      # - volume_m3 = package_volume_liters / 1000 > 0.019 => e.g. 20.0 liters => 0.02 m³
      product = create(:product, sku: "SKU-EP-1", quantity: 10, weight: 9.0, package_volume: 20.0, package_dimensions: "20 x 30 x 40 cm", dimensions: "20 x 30 x 40 cm", full_attributes: {})
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 2) # 2 parcels

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [
          { "WarehouseId" => "bad", "WarehouseName" => "EP bad", "Address7Name" => "Минск", "WarehouseWeightLimit" => "8" },
          { "WarehouseId" => "ok", "WarehouseName" => "EP ok", "Address7Name" => "Минск", "WarehouseWeightLimit" => "50" }
        ]
      )

      get "/api/v1/delivery/europost_offices", params: { cart_id: cart.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      ids = body["offices"].map { |o| o["id"] }
      expect(ids).to contain_exactly("ok")
      expect(body["offices"].first["available_for_cart"]).to be(true)
    end

    it "keeps api office without weight limit as available" do
      cart = create(:cart)
      product = create(:product, sku: "SKU-EP-2", quantity: 10, weight: 3.0, package_volume: 0.01, package_dimensions: "10 x 20 x 30 cm", dimensions: "10 x 20 x 30 cm", full_attributes: {})
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 2)

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "no-limit", "WarehouseName" => "EP no limit", "Address7Name" => "Минск" }]
      )

      get "/api/v1/delivery/europost_offices", params: { cart_id: cart.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      ids = body["offices"].map { |o| o["id"] }
      expect(ids).to include("no-limit")
    end

    it "returns empty offices when cart is not eligible for europost VGH" do
      cart = create(:cart)
      product = create(:product, sku: "SKU-EP-3", quantity: 10, weight: nil, package_volume: nil, package_dimensions: nil, dimensions: nil, full_attributes: {})
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "ok", "WarehouseName" => "EP ok", "Address7Name" => "Минск", "WarehouseWeightLimit" => "50" }]
      )

      get "/api/v1/delivery/europost_offices", params: { cart_id: cart.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"]).to eq([])
    end
  end
end
