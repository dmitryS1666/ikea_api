require 'swagger_helper'

RSpec.describe 'api/v1/checkout', type: :request do

  path '/api/v1/checkout' do
    post('create checkout') do
      tags 'Checkout'
      consumes 'application/json'
      security [ bearer_auth: [] ]
      parameter name: :checkout_data, in: :body, schema: {
        type: :object,
        properties: {
          full_name: { type: :string, example: 'Иван Иванов' },
          phone: { type: :string, example: '79991234567' },
          delivery_type: {
            type: :string,
            enum: %w[pickup europost_pickup courier ikeya_delivery],
            example: 'europost_pickup',
            description: 'pickup — deprecated alias и нормализуется в europost_pickup'
          },
          payment_method: { type: :string, example: 'card' },
          pickup_point_id: { type: :string, example: "70130010", description: "WarehouseId Европочты" },
          delivery_address_id: { type: :integer, example: 12 },
          pickup_point: {
            type: :object,
            properties: {
              id: { type: :string, example: "70130010" },
              external_id: { type: :string, example: '12345' },
              address: { type: :string, example: 'пр-т Пушкина, д. 28' },
              working_hours: { type: :string, example: 'Пн-Вс 10:00-21:00' }
            }
          },
          address: {
            type: :object,
            properties: {
              city: { type: :string, example: 'Минск' },
              street: { type: :string, example: 'ул. Ленина' },
              house: { type: :string, example: '12' },
              is_private_house: { type: :boolean, example: true },
              apartment: { type: :string, nullable: true, example: nil },
              entrance: { type: :string, nullable: true, example: nil },
              floor: { type: :string, nullable: true, example: nil },
              has_elevator: { type: :boolean, nullable: true, example: nil },
              intercom: { type: :string, nullable: true, example: nil }
            }
          },
          draft: { type: :boolean, example: true },
          items: {
            type: :array,
            items: {
              type: :object,
              properties: {
                sku: { type: :string, example: '90205097' },
                quantity: { type: :integer, example: 1 }
              }
            }
          }
        }
      }

      response(201, 'order created') do
        schema type: :object, properties: {
          message: { type: :string, example: 'Заказ успешно оформлен' },
          order_id: { type: :integer }
        }
        run_test!
      end

      response(401, 'unauthorized') do
        run_test!
      end

      response(422, 'unprocessable entity') do
        schema type: :object, properties: {
          error: { type: :string }
        }
        run_test!
      end
    end
  end
end
