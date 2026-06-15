require "swagger_helper"

RSpec.describe "Account Delivery Addresses API", type: :request do
  path "/api/v1/account/delivery_addresses" do
    get "List delivery addresses" do
      tags "Account"
      produces "application/json"
      security [bearer_auth: []]

      response "200", "successful" do
        run_test!
      end
    end

    post "Create delivery address" do
      tags "Account"
      consumes "application/json"
      produces "application/json"
      security [bearer_auth: []]

      parameter name: :payload, in: :body, schema: {
        type: :object,
        required: %w[city street house],
        properties: {
          city: { type: :string, example: "Минск" },
          street: { type: :string, example: "ул. Ленина" },
          house: { type: :string, example: "12" },
          is_private_house: { type: :boolean, example: true },
          apartment: { type: :string, nullable: true, example: nil },
          entrance: { type: :string, nullable: true, example: nil },
          floor: { type: :string, nullable: true, example: nil },
          elevator_type: { type: :string, nullable: true, enum: %w[passenger cargo], example: "passenger" },
          intercom: { type: :string, nullable: true, example: nil },
          lat: { type: :number, example: 53.9 },
          lng: { type: :number, example: 27.56 },
          comment: { type: :string, example: "Частный дом, звонить заранее" }
        }
      }

      response "201", "created" do
        run_test!
      end
    end
  end

  path "/api/v1/account/delivery_addresses/{id}" do
    patch "Update delivery address" do
      tags "Account"
      consumes "application/json"
      produces "application/json"
      security [bearer_auth: []]

      parameter name: :id, in: :path, type: :integer, required: true
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          street: { type: :string, example: "пр-т Победителей" },
          house: { type: :string, example: "101" }
        }
      }

      response "200", "updated" do
        run_test!
      end
    end

    delete "Delete delivery address" do
      tags "Account"
      security [bearer_auth: []]
      parameter name: :id, in: :path, type: :integer, required: true

      response "204", "deleted" do
        run_test!
      end
    end
  end
end
