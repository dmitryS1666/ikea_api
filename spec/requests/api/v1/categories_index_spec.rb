require 'rails_helper'

RSpec.describe 'Api::V1::Categories', type: :request do
  describe 'GET /api/v1/categories' do
    before do
      55.times do |i|
        create(:category, ikea_id: "1000#{i}", unique_id: i, name: "Category #{i}")
      end
    end

    it 'paginates categories with default per_page' do
      get '/api/v1/categories'

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(50)
      expect(body['meta']).to include(
        'total' => 55,
        'page' => 1,
        'per_page' => 50,
        'total_pages' => 2
      )
    end

    it 'returns the next page of categories' do
      get '/api/v1/categories', params: { page: 2 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(5)
      expect(body['meta']).to include(
        'total' => 55,
        'page' => 2,
        'per_page' => 50,
        'total_pages' => 2
      )
    end
  end
end
