require "swagger_helper"

RSpec.describe "Delivery Europost Offices API", type: :request do
  path "/api/v1/delivery/europost_offices" do
    get "List Europost offices (legacy and cart-aware)" do
      tags "Delivery"
      produces "application/json"

      parameter name: :cart_id, in: :query, type: :integer, required: false,
                description: "Если передан, ответ фильтруется по ВГХ корзины и содержит ETA/цены."

      parameter name: :type, in: :query, type: :integer, required: false,
                description: "Фильтр типа ПВЗ для GET /api/external/stores (1, 3, 4). Нужен EUROPOST_API_TOKEN."

      response "200", "successful" do
        schema type: :object, properties: {
          offices: {
            type: :array,
            items: {
              oneOf: [
                { "$ref": "#/components/schemas/EuropostOffice" },
                { "$ref": "#/components/schemas/EuropostOfficeForCart" }
              ]
            }
          }
        }

        run_test!
      end
    end
  end
end
