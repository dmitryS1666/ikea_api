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

    it 'does not embed per-category seo in tree nodes' do
      category = create(
        :category,
        ikea_id: 'dekor',
        translated_name: 'Декор',
        cached_slug: 'dekor',
        parent_ids: []
      )
      create(:seo_metum, seoable: category, seo_text: '<h2>Декор SEO</h2><p>Длинный текст.</p>')

      get '/api/v1/categories/tree'

      expect(response).to have_http_status(:ok)

      node = JSON.parse(response.body).fetch('data').find { |n| n['id'] == 'dekor' }
      expect(node).to be_present
      expect(node.dig('attributes', 'seo')).to be_nil
      expect(node['attributes'].keys).not_to include('seo')
      expect(node).not_to have_key('type')
    end
  end
end
