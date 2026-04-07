FactoryBot.define do
  factory :product do
    sequence(:sku) { |n| "SKU#{n}" }
    name { "Test Product" }
    price { 100.0 }
    quantity { 10 }
  end
end
