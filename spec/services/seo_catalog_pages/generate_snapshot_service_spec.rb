require 'rails_helper'

RSpec.describe SeoCatalogPages::GenerateSnapshotService do
  let!(:category) do
    create(
      :category,
      ikea_id: 'sofas',
      available_filters: [
        {
          'name' => 'Цвет',
          'parameter' => 'f-colors',
          'values' => [{ 'id' => 'white', 'name' => 'Белый' }]
        }
      ]
    )
  end
  let!(:matching_product) do
    create(
      :product,
      sku: 's12345678',
      category_id: category.ikea_id,
      name: 'Sofa PL',
      name_ru: 'Диван',
      price: 100,
      quantity: 10,
      popularity_score: 10,
      local_images: ['/images/products/sofa.webp']
    )
  end
  let!(:other_product) do
    create(
      :product,
      sku: '87654321',
      category_id: category.ikea_id,
      name_ru: 'Кресло',
      price: 150,
      quantity: 0
    )
  end
  let!(:matching_filter_value) do
    create(
      :product_filter_value,
      product: matching_product,
      category_id: category.ikea_id,
      parameter: 'f-colors',
      value_id: 'white'
    )
  end
  let(:page) do
    create(
      :seo_catalog_page,
      :published,
      filter_config: {
        'category_ids' => [category.ikea_id],
        'only_available' => true,
        'sort' => 'popular',
        'limit' => 10
      }
    )
  end

  before do
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(instance_double(ExchangeRate, rate_per_unit: 1.0))
    allow(CalculatorSetting).to receive(:get).and_return(nil)
  end

  it 'generates products snapshot with ProductTeaserSerializer format and category filters' do
    result = described_class.call(page)

    expect(result.products_count).to eq(1)
    page.reload
    expect(page.products_count).to eq(1)
    expect(page.last_generated_at).to be_present

    expect(page.products_snapshot).to include('data', 'meta')
    first_resource = page.products_snapshot['data'].first
    expect(first_resource).to include('id' => matching_product.id.to_s, 'type' => 'product_teaser')
    expect(first_resource['attributes']).to include(
      'sku' => '12345678',
      'slug' => matching_product.slug,
      'name_ru' => 'Диван',
      'local_images' => ['/images/products/sofa.webp']
    )
    expect(first_resource['attributes']['price_byn']).to be_present

    expect(page.filters_snapshot.first).to include('parameter' => 'f-colors')
    expect(page.filters_snapshot.first['values'].first).to include(
      'id' => 'white',
      'name' => 'Белый',
      'count' => 1
    )
  end

  it 'sets indexable false for empty published page' do
    matching_product.update!(quantity: 0)

    described_class.call(page)

    expect(page.reload.products_count).to eq(0)
    expect(page.indexable).to eq(false)
  end

  it 'supports preview without persisting snapshot' do
    result = described_class.new(page, persist: false).preview

    expect(result.products_count).to eq(1)
    expect(result.products_data.first['attributes']['sku']).to eq('12345678')
    expect(result.filters_snapshot.first['parameter']).to eq('f-colors')
    expect(page.reload.products_count).to eq(0)
    expect(page.products_snapshot).to eq([])
    expect(page.filters_snapshot).to eq([])
  end
end
