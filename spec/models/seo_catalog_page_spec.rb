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

  it 'rejects invalid filter_config_json_input' do
    page = build(:seo_catalog_page)
    page.filter_config_json_input = '{bad json'

    expect(page).not_to be_valid
    expect(page.errors[:filter_config]).to be_present
  end

  it 'builds frontend payload paths' do
    page = build(:seo_catalog_page, slug: 'divany-do-1000-byn')

    expect(page.path).to eq('/catalog/seo/divany-do-1000-byn')
    expect(page.frontend_list_payload[:path]).to eq('/catalog/seo/divany-do-1000-byn')
  end
end
