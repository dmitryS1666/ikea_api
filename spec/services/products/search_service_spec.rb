require 'rails_helper'

RSpec.describe Products::SearchService do
  let(:category) { create(:category) }
  let!(:product1) { create(:product, price: 100, rating_weighted: 5, created_at: 1.day.ago) }
  let!(:product2) { create(:product, price: 200, rating_weighted: 4, created_at: 2.days.ago) }
  let!(:product3) { create(:product, price: 50, rating_weighted: 3, created_at: 3.days.ago) }

  before do
    category.products_through_categories << [product1, product2, product3]
  end

  describe '#call' do
    context 'filtering by price' do
      it 'filters by min_price' do
        service = described_class.new(category, { min_price: 150 })
        expect(service.call).to contain_exactly(product2)
      end

      it 'filters by max_price' do
        service = described_class.new(category, { max_price: 150 })
        expect(service.call).to contain_exactly(product1, product3)
      end
    end

    context 'sorting' do
      it 'sorts by cheapest' do
        service = described_class.new(category, { sort: 'cheapest' })
        expect(service.call.to_a).to eq([product3, product1, product2])
      end

      it 'sorts by expensive' do
        service = described_class.new(category, { sort: 'expensive' })
        expect(service.call.to_a).to eq([product2, product1, product3])
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
