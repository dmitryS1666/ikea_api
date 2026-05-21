# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Product reviews API (public)', type: :request do
  let!(:product) { create(:product, sku: 'PUBLIC-REV-1', quantity: 10) }
  let!(:user) { create(:user, first_name: 'Мария', last_name: 'Сидорова') }

  before do
    create(:review, product_sku: product.sku, user: user, rating: 5, body: 'Отличный товар, рекомендую!')
    ProductRatingCalculator.recalculate!(product.sku)
  end

  describe 'GET /api/v1/products/:product_sku/reviews' do
    it 'returns published reviews without auth' do
      get "/api/v1/products/#{product.sku}/reviews"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['data'].size).to eq(1)
      expect(json['data'].first).to include(
        'id' => be_a(Integer),
        'rating' => 5,
        'body' => 'Отличный товар, рекомендую!',
        'author_name' => 'Мария С.',
        'photos' => []
      )
      expect(json['aggregates']).to include('rating_count' => 1)
      expect(json['rating_distribution']).to include('5' => 1)
      expect(json['photos']).to eq([])
      expect(json['meta']).to include('page' => 1, 'total' => 1, 'total_pages' => 1)
    end

    it 'returns 404 for unknown product' do
      get '/api/v1/products/UNKNOWN-SKU/reviews'
      expect(response).to have_http_status(:not_found)
    end
  end
end
