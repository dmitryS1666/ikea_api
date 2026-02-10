require 'swagger_helper'

RSpec.describe 'Account Receipts API', type: :request do
  path '/api/v1/account/receipts' do
    get 'List receipts' do
      tags 'Account'
      produces 'application/json'
      security [bearer_auth: []]

      response '401', 'unauthorized' do
        run_test!
      end
    end
  end
end
