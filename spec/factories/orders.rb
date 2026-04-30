FactoryBot.define do
  factory :order do
    user
    total_amount { 100.0 }
    status { "created" }
    full_name { "Test User" }
    phone { "+375291234567" }
    delivery_type { "pickup" }
    payment_method { "cash" }
    address_json { { city: "Minsk" } }
  end

  factory :order_item do
    order
    product_sku { "123.456.78" }
    quantity { 1 }
    price { 100.0 }
  end

  factory :order_status_event do
    order
    from_status { nil }
    to_status { "created" }
    changed_at { Time.current }
    source { "system" }
    raw_payload { {} }
  end
end
