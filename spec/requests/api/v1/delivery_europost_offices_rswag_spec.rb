require "swagger_helper"

RSpec.describe "Delivery Europost Offices API", type: :request do
  path "/api/v1/delivery/europost_offices" do
    get "List Europost offices (requires delivery context)" do
      tags "Delivery"
      produces "application/json"

      parameter name: :order_id, in: :query, type: :integer, required: false,
                description: "Черновик checkout — фильтрация по составу заказа."
      parameter name: :cart_token, in: :query, type: :string, required: false
      parameter name: :items, in: :query, type: :string, required: false,
                description: "JSON [{sku, quantity}] для subset корзины."
      parameter name: :type, in: :query, type: :integer, required: false

      response "200", "successful" do
        run_test!
      end

      response "422", "delivery context required" do
        run_test!
      end
    end
  end
end
