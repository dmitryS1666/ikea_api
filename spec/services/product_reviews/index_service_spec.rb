# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductReviews::IndexService do
  let!(:product) { create(:product, sku: 'REV-SKU-1', quantity: 5) }
  let!(:user1) { create(:user, first_name: 'Анна', last_name: 'Ковалева') }
  let!(:user2) { create(:user, first_name: 'Иван', last_name: 'Петров') }

  before do
    create(:review, product_sku: product.sku, user: user1, rating: 5, body: 'Пять звёзд', published_at: 2.days.ago)
    create(:review, product_sku: product.sku, user: user2, rating: 4, body: 'Хорошо, всё ок', published_at: 1.day.ago)
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

  context 'with with_photo filter and no matching reviews' do
    let(:params) { { with_photo: '1' } }

    it 'returns an empty stable response instead of raising' do
      expect(result[:data]).to eq([])
      expect(result[:aggregates]).to eq(rating_avg: 0, rating_weighted: 0, rating_count: 0)
      expect(result[:rating_distribution]).to eq('1' => 0, '2' => 0, '3' => 0, '4' => 0, '5' => 0)
      expect(result[:photos]).to eq([])
      expect(result[:meta]).to include(page: 1, per_page: 20, total: 0, total_pages: 0)
    end
  end

  context 'with with_photo filter and matching reviews' do
    before do
      create(:review, :with_photo, product_sku: product.sku, user: create(:user), rating: 5, body: 'С фото есть', published_at: Time.current)
    end

    let(:params) { { with_photo: '1' } }

    it 'returns only reviews that have photos' do
      expect(result[:data].size).to eq(1)
      expect(result[:data].first[:photos]).not_to be_empty
      expect(result[:meta]).to include(total: 1)
    end
  end

  context 'with WEBP review photos' do
    before do
      create(:review, :with_webp_photo, product_sku: product.sku, user: create(:user), rating: 5, body: 'С WEBP фото', published_at: Time.current)
    end

    let(:params) { { with_photo: '1' } }

    it 'keeps published WEBP photo reviews in the with_photo filter' do
      expect(result[:data].size).to eq(1)
      expect(result[:data].first[:body]).to eq('С WEBP фото')
      expect(result[:data].first[:photos]).not_to be_empty
      expect(result[:meta]).to include(total: 1)
    end
  end

  context 'with WEBP review photos stored with generic content type' do
    before do
      create(:review, :with_octet_stream_webp_photo, product_sku: product.sku, user: create(:user), rating: 5, body: 'С WEBP octet-stream фото', published_at: Time.current)
    end

    let(:params) { { with_photo: '1' } }

    it 'treats .webp filename as a photo even when content_type is generic' do
      expect(result[:data].size).to eq(1)
      expect(result[:data].first[:body]).to eq('С WEBP octet-stream фото')
      expect(result[:data].first[:photos]).not_to be_empty
      expect(result[:meta]).to include(total: 1)
    end
  end

  context 'with plural with_photos alias' do
    before do
      create(:review, :with_webp_photo, product_sku: product.sku, user: create(:user), rating: 5, body: 'С фото alias', published_at: Time.current)
    end

    let(:params) { { with_photos: 'true' } }

    it 'supports the frontend plural alias' do
      expect(result[:data].size).to eq(1)
      expect(result[:data].first[:body]).to eq('С фото alias')
    end
  end

  context 'with invalid rating filter' do
    let(:params) { { rating: '6' } }

    it 'raises a controlled validation error' do
      expect { result }.to raise_error(ProductReviews::IndexService::InvalidParameterError, /Invalid rating/)
    end
  end

  context 'with invalid sort' do
    let(:params) { { sort: 'random' } }

    it 'raises a controlled validation error' do
      expect { result }.to raise_error(ProductReviews::IndexService::InvalidParameterError, /Invalid sort/)
    end
  end
end
