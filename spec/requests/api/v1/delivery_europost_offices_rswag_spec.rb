require "swagger_helper"

RSpec.describe "Delivery Europost Offices API", type: :request do
  path "/api/v1/delivery/europost_offices" do
    get "List Europost offices (public catalog or cart-filtered)" do
      tags "Delivery"
      produces "application/json"

      parameter name: :order_id, in: :query, type: :integer, required: false,
                description: "Черновик checkout — фильтрация по составу заказа."
      parameter name: :cart_token, in: :query, type: :string, required: false
      parameter name: :items, in: :query, type: :string, required: false,
                description: "JSON [{sku, quantity}] для subset корзины."
      parameter name: :type, in: :query, type: :integer, required: false,
                description: "Фильтр типа ПВЗ (1 / 3 / 4) для REST stores."
      parameter name: :city, in: :query, type: :string, required: false,
                description: "Фильтр/поиск по городу ПВЗ. Точное совпадение по городу имеет приоритет над совпадениями по области/адресу."
      parameter name: :q, in: :query, type: :string, required: false,
                description: "Алиас city для поиска ПВЗ."
      parameter name: :search, in: :query, type: :string, required: false,
                description: "Алиас city для поиска ПВЗ."

      response "200", "public catalog without delivery context" do
        run_test!
      end
    end
  end
end
