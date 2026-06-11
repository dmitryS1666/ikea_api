require 'rails_helper'

RSpec.describe SeoCatalogPages::GenerateSnapshotService do
  let!(:category) { create(:category, ikea_id: 'sofas') }
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
    allow(CalculatorSetting).to receive(:get).with('exchange_rate_buffer').and_return(1.0)
  end

  it 'generates products snapshot with frontend fields' do
    result = described_class.call(page)

    expect(result.products_count).to eq(1)
    page.reload
    expect(page.products_count).to eq(1)
    expect(page.last_generated_at).to be_present
    expect(page.products_snapshot.first).to include(
      'id' => matching_product.id,
      'sku' => '12345678',
      'slug' => matching_product.slug,
      'name_ru' => 'Диван',
      'available' => true,
      'image_url' => '/images/products/sofa.webp'
    )
    expect(page.products_snapshot.first['price_byn']).to match(/\A\d+\.\d{2}\z/)
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
    expect(page.reload.products_count).to eq(0)
    expect(page.products_snapshot).to eq([])
  end
end
