FactoryBot.define do
  factory :featured_product_tab do
    list_key { "bestsellers" }
    category_id { create(:category).ikea_id }
    product_skus { ["SKU123"] }
    position { 0 }
    active { true }
  end
end
