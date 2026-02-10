require 'swagger_helper'

RSpec.describe 'Account Purchases API', type: :request do
  path '/api/v1/account/purchases' do
    get 'List purchases' do
      tags 'Account'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :sort, in: :query, type: :string, required: false, description: 'newest|oldest|price_asc|price_desc'

      response '401', 'unauthorized' do
        run_test!
      end
    end
  end
end
