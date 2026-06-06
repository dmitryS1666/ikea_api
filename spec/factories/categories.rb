FactoryBot.define do
  factory :category do
    sequence(:ikea_id) { |n| "category_#{n}" }
    sequence(:unique_id) { |n| n }
    name { "MyString" }
    translated_name { "MyString" }
    url { "MyString" }
    remote_image_url { "MyString" }
    local_image_path { "MyString" }
    parent_ids { "MyText" }
    is_deleted { false }
    is_important { false }
    is_popular { false }
    available_filters { [] }
  end
end
