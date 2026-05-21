# frozen_string_literal: true

FactoryBot.define do
  factory :review do
    association :user
    product_sku { create(:product).sku }
    rating { 5 }
    body { 'Отличный товар, всё понравилось!' }
    status { :published }
    published_at { Time.current }

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
  end
end
