# frozen_string_literal: true

FactoryBot.define do
  factory :product_recommendation_setting do
    placement { :cart }
    source_type { :sku_list }
    active { true }
    product_skus { [] }
    category_id { nil }
  end
end
