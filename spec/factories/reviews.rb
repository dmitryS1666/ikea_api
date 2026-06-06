# frozen_string_literal: true

FactoryBot.define do
  factory :review do
    association :user
    product_sku { create(:product).sku }
    rating { 5 }
    body { 'Отличный товар, всё понравилось!' }
    status { :published }
    published_at { Time.current }

    # Review model validates that the user has purchased the product.
    # Most service specs focus on published-review indexing, so the factory
    # creates the minimal purchased order unless a test supplied one explicitly.
    before(:create) do |review|
      next if review.order.present?
      next if review.user.blank? || review.product_sku.blank?

      # Keep this synthetic purchase local to the review factory. The review
      # validation only needs a purchased order with a matching item; CRM sync
      # callbacks are irrelevant here and make isolated service specs noisy.
      order = create(:order, user: review.user, status: :completed, checkout_draft: true)
      create(:order_item, order: order, product_sku: review.product_sku, quantity: 1)
      review.order = order
    end

    trait :pending do
      status { :pending }
      published_at { nil }
    end

    trait :with_photo do
      after(:create) do |review|
        review.photos.attach(
          io: StringIO.new('fake-image'),
          filename: 'review.jpg',
          content_type: 'image/jpeg'
        )
      end
    end

    trait :with_webp_photo do
      after(:create) do |review|
        review.photos.attach(
          io: StringIO.new('fake-webp-image'),
          filename: 'review.webp',
          content_type: 'image/webp'
        )
      end
    end

    trait :with_octet_stream_webp_photo do
      after(:create) do |review|
        review.photos.attach(
          io: StringIO.new('fake-webp-image'),
          filename: 'review.webp',
          content_type: 'application/octet-stream'
        )
      end
    end
  end
end
