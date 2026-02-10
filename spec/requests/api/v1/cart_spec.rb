require 'swagger_helper'

RSpec.describe 'Cart API', type: :request do
  path '/api/v1/cart' do
    get 'Show cart' do
      tags 'Cart'
      produces 'application/json'

      parameter name: :cart_token, in: :query, type: :string, required: false

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/cart_items' do
    delete 'Delete selected cart items or clear cart' do
      tags 'Cart'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          skus: { type: :array, items: { type: :string }, example: ['123.456.78'] },
          delete_all: { type: :boolean, example: false }
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

  path '/api/v1/cart/promo/apply' do
    post 'Apply promo code' do
      tags 'Cart'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: { code: { type: :string, example: 'PROMO10' } },
        required: ['code']
      }

      response '200', 'successful' do
        run_test!
      end

      response '422', 'unprocessable entity' do
        run_test!
      end
    end
  end

  path '/api/v1/cart/promo/remove' do
    post 'Remove promo code' do
      tags 'Cart'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
