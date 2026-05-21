# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductReviews::IndexService do
  let!(:product) { create(:product, sku: 'REV-SKU-1', quantity: 5) }
  let!(:user1) { create(:user, first_name: 'Анна', last_name: 'Ковалева') }
  let!(:user2) { create(:user, first_name: 'Иван', last_name: 'Петров') }

  before do
    create(:review, product_sku: product.sku, user: user1, rating: 5, body: 'Пять звёзд', published_at: 2.days.ago)
    create(:review, product_sku: product.sku, user: user2, rating: 4, body: 'Хорошо', published_at: 1.day.ago)
    create(:review, :pending, product_sku: product.sku, user: create(:user), rating: 3)
    ProductRatingCalculator.recalculate!(product.sku)
    product.reload
  end

  subject(:result) { described_class.new(product: product, params: params).call }

  let(:params) { {} }

  it 'returns published reviews with aggregates and meta' do
    expect(result[:data].size).to eq(2)
    expect(result[:aggregates]).to include(
      rating_avg: product.rating_avg.to_f,
      rating_weighted: product.rating_weighted.to_f,
      rating_count: 2
    )
    expect(result[:rating_distribution]).to eq('5' => 1, '4' => 1, '3' => 0, '2' => 0, '1' => 0)
    expect(result[:meta]).to include(page: 1, per_page: 20, total: 2, total_pages: 1)
  end

  it 'masks author name' do
    author = result[:data].find { |r| r[:rating] == 5 }[:author_name]
    expect(author).to eq('Анна К.')
  end

  context 'with rating filter' do
    let(:params) { { rating: 5 } }

    it 'filters by rating' do
      expect(result[:data].size).to eq(1)
      expect(result[:data].first[:rating]).to eq(5)
    end
  end

  context 'with sort oldest' do
    let(:params) { { sort: 'oldest' } }

    it 'orders oldest first after pinned' do
      expect(result[:data].map { |r| r[:rating] }).to eq([5, 4])
    end
  end
end
