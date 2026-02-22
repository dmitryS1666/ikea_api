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

  end
end
