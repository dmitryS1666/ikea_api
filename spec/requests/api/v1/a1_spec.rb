require 'swagger_helper'

RSpec.describe 'A1 (stub) API', type: :request do
  path '/api/v1/a1/request' do
    post 'Request A1 verification (stub)' do
      tags 'A1'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          phone: { type: :string, example: '375291234567' }
        },
        required: ['phone']
      }

      response '200', 'successful' do
        run_test!
      end

      response '422', 'unprocessable entity' do
        run_test!
      end
    end
  end

  path '/api/v1/a1/verify' do
    post 'Verify A1 last4 (stub)' do
      tags 'A1'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          verification_id: { type: :integer, example: 1 },
          last4: { type: :string, example: '1234' }
        },
        required: %w[verification_id last4]
      }

      response '200', 'verified' do
        run_test!
      end

      response '401', 'unauthorized' do
        run_test!
      end

      response '422', 'unprocessable entity' do
        run_test!
      end
    end
  end
end
