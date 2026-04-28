require 'swagger_helper'

RSpec.describe 'Delivery API', type: :request do
  path '/api/v1/delivery/types' do
    get 'List delivery types' do
      tags 'Delivery'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/delivery/calculate' do
    post 'Calculate delivery' do
      tags 'Delivery'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          cart_token: { type: :string, example: 'guest_token_123' },
          delivery_type: {
            type: :string,
            enum: %w[pickup europost_pickup courier ikeya_delivery],
            example: 'courier',
            description: 'pickup — deprecated alias и нормализуется в europost_pickup'
          },
          pickup_point_id: { type: :integer, example: 1 }
        }
      }

      response '200', 'successful' do
        run_test!
      end

      response '422', 'unprocessable entity' do
        run_test!
      end
    end
  end

  path '/api/v1/delivery/pickup_points' do
    get 'List pickup points' do
      tags 'Delivery'
      produces 'application/json'

      parameter name: :city, in: :query, type: :string, required: false

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/delivery/pickup_points_search' do
    get 'Search pickup points' do
      tags 'Delivery'
      produces 'application/json'

      parameter name: :query, in: :query, type: :string, required: true

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
