require 'swagger_helper'

RSpec.describe 'Categories API (public)', type: :request do
  path '/api/v1/categories' do
    get 'List categories' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/categories/{id}' do
    get 'Show category' do
      tags 'Categories'
      produces 'application/json'
      parameter name: :id, in: :path, type: :integer, required: true

      response '404', 'not found' do
        let(:id) { 999_999 }
        run_test!
      end
    end
  end

  path '/api/v1/categories/tree' do
    get 'Categories tree' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/categories/map' do
    get 'Categories map' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/categories/popular' do
    get 'Popular categories' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
