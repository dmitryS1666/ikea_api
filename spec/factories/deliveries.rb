FactoryBot.define do
  factory :delivery do
    weight { "9.99" }
    delivery_type { "MyString" }
    is_ikea_family { false }
    order_value { "9.99" }
    is_weekend { false }
  end
end
