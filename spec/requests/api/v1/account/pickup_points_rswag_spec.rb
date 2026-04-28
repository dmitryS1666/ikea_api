require "swagger_helper"

RSpec.describe "Account Pickup Points API", type: :request do
  path "/api/v1/account/pickup_points" do
    get "List user pickup points" do
      tags "Account"
      produces "application/json"
      security [bearer_auth: []]

      response "200", "successful" do
        run_test!
      end
    end

    post "Create or reuse user pickup point" do
      tags "Account"
      consumes "application/json"
      produces "application/json"
      security [bearer_auth: []]

      parameter name: :payload, in: :body, schema: {
        type: :object,
        required: %w[provider external_id],
        properties: {
          provider: { type: :string, enum: %w[europost], example: "europost" },
          external_id: { type: :string, example: "12345" },
          pickup_point_id: { type: :integer, example: 10 },
          city: { type: :string, example: "Минск" },
          address: { type: :string, example: "пр-т Пушкина, д. 28" },
          working_hours: { type: :string, example: "Пн-Вс 10:00-21:00" },
          lat: { type: :number, example: 53.9123 },
          lng: { type: :number, example: 27.4567 },
          raw_payload: { type: :object, example: {} }
        }
      }

      response "201", "created" do
        run_test!
      end

      response "200", "already existed and was updated" do
        run_test!
      end
    end
  end

  path "/api/v1/account/pickup_points/{id}" do
    delete "Delete user pickup point" do
      tags "Account"
      security [bearer_auth: []]
      parameter name: :id, in: :path, type: :integer, required: true

      response "204", "deleted" do
        run_test!
      end
    end
  end
end
