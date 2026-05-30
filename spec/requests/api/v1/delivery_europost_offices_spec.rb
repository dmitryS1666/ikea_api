require "rails_helper"

RSpec.describe "Delivery Europost offices", type: :request do
  describe "GET /api/v1/delivery/europost_offices" do
    before do
      stub_request(:get, %r{\Ahttps://api-kassa\.evropochta\.by/api/external/stores})
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
      allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.0))
      allow(PriceCalculationService).to receive(:exchange_rate_buffer).and_return(1.0)
    end

    it "returns public office catalog without delivery context" do
      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{
          "WarehouseId" => "70130010",
          "WarehouseName" => "ПВЗ Минск-1",
          "Address7Name" => "Минск",
          "Address5Name" => "ул. Примерная",
          "Address4Name" => "1",
          "Latitude" => "53.9",
          "Longitude" => "27.5",
          "WarehouseWeightLimit" => "50"
        }]
      )

      get "/api/v1/delivery/europost_offices"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"].size).to eq(1)
      office = body["offices"].first
      expect(office["id"]).to eq("70130010")
      expect(office["city"]).to eq("Минск")
      expect(office["max_weight_kg"]).to eq(50.0)
      expect(office).not_to have_key("available_for_cart")
      expect(office).not_to have_key("delivery_price_byn")
    end


    it "filters public offices by exact city first instead of matching region names" do
      allow(EuropostApiService).to receive(:offices_out).and_return(
        [
          {
            "WarehouseId" => "gomel-city",
            "WarehouseName" => "ПВЗ Гомель",
            "Address7Name" => "Гомель",
            "Address5Name" => "ул. Советская",
            "Address4Name" => "1",
            "WarehouseWeightLimit" => "50"
          },
          {
            "WarehouseId" => "kalinkovichi",
            "WarehouseName" => "ПВЗ Калинковичи, Гомельская область",
            "Address7Name" => "Калинковичи",
            "Address5Name" => "ул. Ленина",
            "Address4Name" => "2",
            "WarehouseWeightLimit" => "50"
          }
        ]
      )

      get "/api/v1/delivery/europost_offices", params: { city: "Гомель" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"].map { |office| office["id"] }).to eq(["gomel-city"])
    end

    it "supports q/search aliases for city lookup" do
      allow(EuropostApiService).to receive(:offices_out).and_return(
        [
          { "WarehouseId" => "gomel", "WarehouseName" => "ПВЗ Гомель", "Address7Name" => "Гомель" },
          { "WarehouseId" => "kalinkovichi", "WarehouseName" => "ПВЗ Калинковичи", "Address7Name" => "Калинковичи" }
        ]
      )

      get "/api/v1/delivery/europost_offices", params: { q: "Калинковичи" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"].map { |office| office["id"] }).to eq(["kalinkovichi"])
    end

    it "filters offices by cart_token" do
      cart = create(:cart)
      product = create(:product, sku: "SKU-EP-4", quantity: 10, weight: 5, package_volume: 0.02,
                               package_dimensions: "20 x 30 x 140 cm", dimensions: "20 x 30 x 140 cm", full_attributes: {})
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "ok", "WarehouseName" => "EP ok", "Address7Name" => "Минск", "WarehouseWeightLimit" => "50" }]
      )

      get "/api/v1/delivery/europost_offices", params: { cart_token: cart.guest_token }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"]).to eq([])
    end

    it "filters offices by cart_token and items subset" do
      cart = create(:cart)
      light = create(:product, sku: "SKU-EP-L-#{SecureRandom.hex(3)}", quantity: 10, weight: 2, package_volume: 0.005,
                               package_dimensions: "10 x 20 x 30 cm", dimensions: "10 x 20 x 30 cm",
                               full_attributes: {
                                 "dimensions_map" => {
                                   "packaging" => {
                                     "details" => [
                                       { "weight" => "2 кг", "count" => 1, "width" => "10 см", "height" => "20 см", "length" => "30 см" }
                                     ]
                                   }
                                 }
                               })
      heavy = create(:product, sku: "SKU-EP-H-#{SecureRandom.hex(3)}", quantity: 10, weight: 50, package_volume: 0.02,
                               package_dimensions: "20 x 30 x 140 cm", dimensions: "20 x 30 x 140 cm", full_attributes: {})
      create(:cart_item, cart: cart, product_sku: light.sku, quantity: 1)
      create(:cart_item, cart: cart, product_sku: heavy.sku, quantity: 1)

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "ok", "WarehouseName" => "EP ok", "Address7Name" => "Минск", "WarehouseWeightLimit" => "50" }]
      )

      get "/api/v1/delivery/europost_offices",
          params: {
            cart_token: cart.guest_token,
            # GET query params do not preserve nested arrays consistently across Rack/Rails versions.
            # Send items as JSON, which is also supported by CartSelectionService.parse_items_param.
            items: [{ sku: light.sku, quantity: 1 }].to_json
          }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"].map { |o| o["id"] }).to contain_exactly("ok")
    end

    it "filters offices by checkout draft order_id" do
      user = create(:user)
      order = create(:order, user: user, checkout_draft: true)
      product = create(:product, sku: "SKU-EP-5", quantity: 10, weight: 10, package_volume: 0.02,
                               package_dimensions: "20 x 30 x 140 cm", dimensions: "20 x 30 x 140 cm", full_attributes: {})
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 100.0)

      allow(EuropostApiService).to receive(:offices_out).and_return(
        [{ "WarehouseId" => "ok", "WarehouseName" => "EP ok", "Address7Name" => "Минск", "WarehouseWeightLimit" => "50" }]
      )

      get "/api/v1/delivery/europost_offices", params: { order_id: order.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["offices"]).to eq([])
    end

    it "returns 404 when order_id points to non-draft order" do
      order = create(:order, checkout_draft: false)

      get "/api/v1/delivery/europost_offices", params: { order_id: order.id }

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("draft_not_found")
    end
  end
end
