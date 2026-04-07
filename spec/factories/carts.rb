FactoryBot.define do
  factory :cart do
    user
    guest_token { SecureRandom.uuid }
    expires_at { 1.day.from_now }
  end

  factory :cart_item do
    cart
    product_sku { "SKU123" }
    quantity { 1 }
  end
end
