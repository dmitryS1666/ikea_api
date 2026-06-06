require 'rails_helper'

RSpec.describe Products::SearchService do
  let(:category) { create(:category) }
  let!(:product1) { create(:product, price: 100, rating_weighted: 5, created_at: 1.day.ago) }
  let!(:product2) { create(:product, price: 200, rating_weighted: 4, created_at: 2.days.ago) }
  let!(:product3) { create(:product, price: 50, rating_weighted: 3, created_at: 3.days.ago) }

  before do
    category.products_through_categories << [product1, product2, product3]
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(instance_double(ExchangeRate, rate_per_unit: 1.0))
    allow(CalculatorSetting).to receive(:get).with("exchange_rate_buffer").and_return(1.0)
  end

  def display_price_byn(product)
    PriceCalculationService.product_storefront_price_byn(
      product.price.to_f,
      weight_kg: product.packaging_weight_kg.to_f,
      delivery_pln: product.delivery_cost.to_f,
      pln_rate: 1.0,
      buffer: 1.0
    )
  end

  describe '#call' do
    context 'filtering by price' do
      it 'filters by min_price in BYN (display price)' do
        threshold = [display_price_byn(product1), display_price_byn(product3)].max + 0.01
        service = described_class.new(category, { min_price: threshold })
        expect(service.call).to contain_exactly(product2)
      end

      it 'filters by max_price in BYN (display price)' do
        threshold = [display_price_byn(product1), display_price_byn(product3)].max + 0.01
        service = described_class.new(category, { max_price: threshold })
        expect(service.call).to contain_exactly(product1, product3)
      end

      it 'filters by min_price from nested f-price-buckets hash' do
        threshold = display_price_byn(product2) - 0.01
        service = described_class.new(category, { filters: { "f-price-buckets" => { "min" => threshold } } })
        expect(service.call).to contain_exactly(product2)
      end
    end

    context 'filtering by f-price-buckets value ids' do
      before do
        create(:product_filter_value,
               product: product1,
               category_id: category.ikea_id,
               parameter: "f-price-buckets",
               value_id: "PRICE_10000_10001")
        create(:product_filter_value,
               product: product2,
               category_id: category.ikea_id,
               parameter: "f-price-buckets",
               value_id: "PRICE_20000_20001")
      end

      it 'filters by indexed bucket ids' do
        service = described_class.new(category, { filters: { "f-price-buckets" => ["PRICE_10000_10001"] } })
        expect(service.call).to contain_exactly(product1)
      end

      it 'ignores PRICE_RANGE sentinel without min/max' do
        service = described_class.new(category, { filters: { "f-price-buckets" => ["PRICE_RANGE"] } })
        expect(service.call).to contain_exactly(product1, product2, product3)
      end
    end

    context 'sorting' do
      it 'sorts by cheapest (display price BYN)' do
        service = described_class.new(category, { sort: 'cheapest' })
        ordered = service.call.to_a
        prices = ordered.map { |p| display_price_byn(p) }
        expect(prices).to eq(prices.sort)
        expect(ordered).to eq([product3, product1, product2])
      end

      it 'sorts by expensive (display price BYN)' do
        service = described_class.new(category, { sort: 'expensive' })
        ordered = service.call.to_a
        prices = ordered.map { |p| display_price_byn(p) }
        expect(prices).to eq(prices.sort.reverse)
        expect(ordered).to eq([product2, product1, product3])
      end

      it 'sorts by newest' do
        service = described_class.new(category, { sort: 'newest' })
        expect(service.call.to_a).to eq([product1, product2, product3])
      end

      it 'sorts by popular (rating_weighted fallback)' do
        service = described_class.new(category, { sort: 'popular' })
        expect(service.call.to_a).to eq([product1, product2, product3])
      end
    end

    context 'filtering by available_filters values' do
      before do
        create(:product_filter_value,
               product: product1,
               category_id: category.ikea_id,
               parameter: "f-type",
               value_id: "50310")
        create(:product_filter_value,
               product: product2,
               category_id: category.ikea_id,
               parameter: "f-type",
               value_id: "99999")
      end

      it 'filters by single value_id' do
        service = described_class.new(category, { filters: { "f-type" => "50310" } })
        expect(service.call).to contain_exactly(product1)
      end

      it 'filters by multiple value_ids' do
        service = described_class.new(category, { filters: { "f-type" => ["50310", "99999"] } })
        expect(service.call).to contain_exactly(product1, product2)
      end

      it 'matches filter rows indexed on a descendant category' do
        parent = create(:category, ikea_id: 'filter_parent')
        create(:category, ikea_id: 'filter_child', parent_ids: ['filter_parent'])
        child_product = create(:product, price: 100, quantity: 10)
        CategoryProduct.create!(category_id: 'filter_child', product: child_product)
        create(:product_filter_value,
               product: child_product,
               category_id: 'filter_child',
               parameter: 'f-type',
               value_id: '50310')

        service = described_class.new(parent, { filters: { 'f-type' => '50310' } })
        expect(service.call).to contain_exactly(child_product)
      end
    end

    context 'with base_scope (global search)' do
      let!(:scoped_product) { create(:product, sku: "SCOPE-001", name: "Scoped chair", price: 150, quantity: 5) }
      let!(:other_product) { create(:product, sku: "OTHER-001", name: "Other table", price: 80, quantity: 5) }

      before do
        create(:product_filter_value,
               product: scoped_product,
               category_id: category.ikea_id,
               parameter: "f-color",
               value_id: "1")
      end

      it 'filters within the provided scope only' do
        base = Product.where(id: scoped_product.id)
        service = described_class.new(nil, { filters: { "f-color" => "1" } }, base_scope: base)
        expect(service.call).to contain_exactly(scoped_product)
      end

      it 'filters by min_price within base scope' do
        base = Product.where(id: [scoped_product.id, other_product.id])
        threshold = display_price_byn(other_product) + 0.01
        service = described_class.new(nil, { min_price: threshold }, base_scope: base)
        expect(service.call).to contain_exactly(scoped_product)
      end

      it 'keeps relevance order when default_sort is relevance' do
        base = Product.in_order_of(:id, [other_product.id, scoped_product.id])
        service = described_class.new(nil, {}, base_scope: base, default_sort: "relevance")
        expect(service.call.pluck(:id)).to eq([other_product.id, scoped_product.id])
      end
    end

    context 'parent category includes products from descendant categories' do
      let!(:parent_category) { create(:category, ikea_id: 'root_parent') }
      let!(:child_category) do
        create(:category, ikea_id: 'root_child', parent_ids: ['root_parent'])
      end
      let!(:parent_direct_product) do
        create(:product, category_id: parent_category.ikea_id, price: 100, quantity: 10)
      end
      let!(:child_product) do
        create(:product, category_id: child_category.ikea_id, price: 200, quantity: 10)
      end

      it 'returns products linked to self and to descendants' do
        service = described_class.new(parent_category, {})
        expect(service.call).to contain_exactly(parent_direct_product, child_product)
      end
    end

  end
end
