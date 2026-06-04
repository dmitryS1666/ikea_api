require 'swagger_helper'

RSpec.describe 'Reviews API', type: :request do
  path '/api/v1/products/{product_sku}/reviews' do
    get 'List product reviews (public)' do
      tags 'Reviews'
      produces 'application/json'

      parameter name: :product_sku, in: :path, type: :string, required: true
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false
      parameter name: :rating, in: :query, type: :integer, required: false, description: 'Фильтр по оценке 1–5'
      parameter name: :with_photo, in: :query, type: :boolean, required: false
      parameter name: :sort, in: :query, type: :string, required: false,
                description: 'newest (default) | oldest | rating_high | rating_low | helpful; invalid values return 422'

      response '422', 'invalid filter parameter' do
        let!(:product) { create(:product, sku: 'REVIEWS-SWAGGER-SKU', quantity: 10) }
        let(:product_sku) { product.sku }
        let(:rating) { 6 }

        run_test!
      end

      response '404', 'product not found' do
        let(:product_sku) { 'NON_EXISTING_SKU' }
        run_test!
      end
    end

    post 'Create review' do
      tags 'Reviews'
      consumes 'application/json'
      produces 'application/json'
      security [bearer_auth: []]

      parameter name: :product_sku, in: :path, type: :string, required: true
      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          rating: { type: :integer, example: 5 },
          text: { type: :string, example: 'Отличный товар' }
        },
        required: %w[rating text]
      }

      response '401', 'unauthorized' do
        let(:product_sku) { 'NON_EXISTING_SKU' }
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
