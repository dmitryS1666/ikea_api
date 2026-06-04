require 'rails_helper'

RSpec.describe 'Categories tree catalog SEO', type: :request do
  before { Rails.cache.clear }

  describe 'GET /api/v1/categories/tree' do
    it 'keeps the existing tree response without catalog_seo when catalog SEO is not configured' do
      get '/api/v1/categories/tree'

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body).to include('data')
      expect(body).not_to include('catalog_seo')
    end

    it 'adds catalog_seo beside the existing data array' do
      create(
        :global_seo_setting,
        target_type: 'catalog',
        h1_template: 'Каталог',
        title_template: 'Каталог товаров — IKEYA',
        description_template: 'Мебель и товары для дома с доставкой в Беларусь.',
        seo_text: '<h2>Каталог товаров IKEYA</h2><p>Выбирайте мебель и товары для дома.</p>'
      )

      get '/api/v1/categories/tree'

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body).to include('data')
      expect(body['data']).to be_an(Array)
      expect(body['catalog_seo']).to eq(
        'title' => 'Каталог',
        'meta_title' => 'Каталог товаров — IKEYA',
        'meta_description' => 'Мебель и товары для дома с доставкой в Беларусь.',
        'seo_text' => '<h2>Каталог товаров IKEYA</h2><p>Выбирайте мебель и товары для дома.</p>'
      )
    end
  end
end
