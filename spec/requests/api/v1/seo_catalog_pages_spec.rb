require 'rails_helper'

RSpec.describe 'SeoCatalogPages API', type: :request do
  let!(:draft_page) { create(:seo_catalog_page, slug: 'draft-page', status: :draft) }
  let!(:published_page) do
    create(
      :seo_catalog_page,
      :published,
      slug: 'divany-do-1000-byn',
      h1: 'Диваны до 1000 BYN',
      meta_title: 'Диваны до 1000 BYN — купить с доставкой',
      meta_description: 'Подборка диванов до 1000 BYN с доставкой в Беларусь.',
      filter_config: { 'max_price' => 1000, 'only_available' => true },
      products_snapshot: [{ id: 1, sku: '12345678' }],
      products_count: 1,
      last_generated_at: Time.zone.parse('2026-06-11 10:00:00')
    )
  end

  describe 'GET /api/v1/seo_catalog_pages' do
    it 'returns published pages for frontend build' do
      get '/api/v1/seo_catalog_pages'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['data'].map { |item| item['slug'] }).to eq(['divany-do-1000-byn'])
      expect(body['data'].first).to include(
        'path' => '/catalog/seo/divany-do-1000-byn',
        'indexable' => true,
        'products_count' => 1
      )
    end

    it 'filters sitemap pages by indexable and products_count' do
      published_page.update!(products_count: 0, indexable: false)

      get '/api/v1/seo_catalog_pages', params: { sitemap: true }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end
  end

  describe 'GET /api/v1/seo_catalog_pages/:slug' do
    it 'returns full published page payload' do
      get '/api/v1/seo_catalog_pages/divany-do-1000-byn'

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data).to include(
        'slug' => 'divany-do-1000-byn',
        'path' => '/catalog/seo/divany-do-1000-byn',
        'h1' => 'Диваны до 1000 BYN',
        'canonical_path' => '/catalog/seo/divany-do-1000-byn',
        'products_count' => 1
      )
      expect(data['filters']).to eq('max_price' => 1000, 'only_available' => true)
      expect(data['products']).to eq([{ 'id' => 1, 'sku' => '12345678' }])
    end

    it 'does not expose drafts' do
      get '/api/v1/seo_catalog_pages/draft-page'

      expect(response).to have_http_status(:not_found)
    end
  end
end
