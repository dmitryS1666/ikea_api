require 'swagger_helper'

RSpec.describe 'Filters API', type: :request do
  path '/api/v1/filters' do
    get 'List filters' do
      tags 'Filters'
      produces 'application/json'

      parameter name: :category_id, in: :query, type: :integer, required: false, description: 'Optional category ID'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
