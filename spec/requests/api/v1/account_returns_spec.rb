require 'swagger_helper'

RSpec.describe 'Account Returns API', type: :request do
  path '/api/v1/account/returns' do
    get 'List return requests' do
      tags 'Account'
      produces 'application/json'
      security [bearer_auth: []]

      response '401', 'unauthorized' do
        run_test!
      end
    end

    post 'Create return request' do
      tags 'Account'
      consumes 'application/json'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          order_id: { type: :integer, example: 1 },
          reason: { type: :string, example: 'Не подошёл размер' },
          comment: { type: :string, example: 'Хочу вернуть' }
        },
        required: %w[order_id reason]
      }

      response '401', 'unauthorized' do
        run_test!
      end
    end
  end
end
