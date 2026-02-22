FactoryBot.define do
  factory :product_filter_value do
    product
    category_id { "123" }
    parameter { "f-type" }
    value_id { "50310" }
  end
end
