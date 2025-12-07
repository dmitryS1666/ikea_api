FactoryBot.define do
  factory :product do
    sku { "MyString" }
    unique_id { 1 }
    item_no { "MyString" }
    url { "MyString" }
    name { "MyString" }
    name_ru { "MyString" }
    collection { "MyString" }
    variants { "MyText" }
    related_products { "MyText" }
    set_items { "MyText" }
    bundle_items { "MyText" }
    images { "MyText" }
    local_images { "MyText" }
    images_total { 1 }
    images_stored { 1 }
    images_incomplete { false }
    videos { "MyText" }
    manuals { "MyText" }
    price { "9.99" }
    quantity { 1 }
    home_delivery { "MyString" }
    weight { "9.99" }
    net_weight { "9.99" }
    package_volume { "9.99" }
    package_dimensions { "MyString" }
    dimensions { "MyString" }
    is_parcel { false }
    content { "MyText" }
    content_ru { "MyText" }
    material_info { "MyText" }
    material_info_ru { "MyText" }
    good_info { "MyText" }
    good_info_ru { "MyText" }
    translated { false }
    is_bestseller { false }
    is_popular { false }
    category_id { "MyString" }
    delivery_type { "MyString" }
    delivery_name { "MyString" }
    delivery_cost { "9.99" }
    delivery_reason { "MyString" }
  end
end
