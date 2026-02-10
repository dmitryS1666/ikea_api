require 'swagger_helper'

RSpec.describe 'Reviews API', type: :request do
  path '/api/v1/products/{sku}/reviews' do
    post 'Create review' do
      tags 'Reviews'
      consumes 'application/json'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :sku, in: :path, type: :string, required: true
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          rating: { type: :integer, example: 5 },
          text: { type: :string, example: 'Отличный товар' }
        },
        required: %w[rating text]
      }

      response '401', 'unauthorized' do
        let(:sku) { 'NON_EXISTING_SKU' }
        run_test!
      end
    end
  end

  path '/api/v1/account/reviews' do
    get 'My reviews' do
      tags 'Reviews'
      produces 'application/json'
      security [bearer_auth: []]

      response '401', 'unauthorized' do
        run_test!
      end
    end
  end

  path '/api/v1/reviews/{id}' do
    patch 'Update my review' do
      tags 'Reviews'
      consumes 'application/json'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :id, in: :path, type: :integer, required: true
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: { text: { type: :string, example: 'Обновлённый отзыв' } }
      }

      response '401', 'unauthorized' do
        let(:id) { 1 }
        run_test!
      end
    end

    delete 'Delete my review' do
      tags 'Reviews'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :id, in: :path, type: :integer, required: true

      response '401', 'unauthorized' do
        let(:id) { 1 }
        run_test!
      end
    end
  end
end
