require 'rails_helper'

RSpec.describe SeoCatalogPage, type: :model do
  it 'requires URL-safe slug' do
    page = build(:seo_catalog_page, slug: 'Bad Slug!')

    expect(page).not_to be_valid
    expect(page.errors[:slug]).to be_present
  end

  it 'requires SEO fields and filter_config for published page' do
    page = build(:seo_catalog_page, :published, h1: nil, meta_title: nil, meta_description: nil, filter_config: {})

    expect(page).not_to be_valid
    expect(page.errors[:h1]).to be_present
    expect(page.errors[:meta_title]).to be_present
    expect(page.errors[:meta_description]).to be_present
    expect(page.errors[:filter_config]).to be_present
  end

  it 'parses filter_config_json_input from admin form' do
    page = build(:seo_catalog_page)
    page.filter_config_json_input = '{"category_ids":["fb001"],"only_available":true}'

    expect(page).to be_valid
    expect(page.filter_config).to eq("category_ids" => ["fb001"], "only_available" => true)
  end

  it 'rejects unsupported filters in filter_config' do
    page = build(:seo_catalog_page)
    page.filter_config_json_input = '{"category_ids":["fb001"],"filters":{"f-colors":["white"]}}'

    expect(page).not_to be_valid
    expect(page.errors[:filter_config]).to be_present
  end

  it 'accepts collection filter in filter_config' do
    page = build(:seo_catalog_page)
    page.filter_config_json_input = '{"category_ids":["fb001"],"filters":{"series":["PAX"]}}'

    expect(page).to be_valid
    expect(page.filter_config).to eq(
      "category_ids" => ["fb001"],
      "filters" => { "series" => ["PAX"] }
    )
  end

  it 'rejects invalid filter_config_json_input' do
    page = build(:seo_catalog_page)
    page.filter_config_json_input = '{bad json'

    expect(page).not_to be_valid
    expect(page.errors[:filter_config]).to be_present
  end

  it 'normalizes legacy products array snapshot for API' do
    page = build(:seo_catalog_page, products_snapshot: [{ 'sku' => '12345678' }])

    expect(page.products_snapshot_for_api).to eq(
      'data' => [{ 'sku' => '12345678' }],
      'meta' => { 'total' => 1 }
    )
  end

  it 'exposes filter_config separately from available filters' do
    page = build(
      :seo_catalog_page,
      filter_config: { 'max_price' => 1000 },
      filters_snapshot: [{ 'parameter' => 'f-colors', 'values' => [] }]
    )

    payload = page.frontend_detail_payload
    expect(payload[:filter_config]).to eq('max_price' => 1000)
    expect(payload[:filters]).to eq([{ 'parameter' => 'f-colors', 'values' => [] }])
    expect(payload[:available_filters]).to eq(payload[:filters])
  end

  it 'builds frontend payload paths' do
    page = build(:seo_catalog_page, slug: 'divany-do-1000-byn')

    expect(page.path).to eq('/catalog/seo/divany-do-1000-byn')
    expect(page.frontend_list_payload[:path]).to eq('/catalog/seo/divany-do-1000-byn')
  end
end
