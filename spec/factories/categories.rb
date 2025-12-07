FactoryBot.define do
  factory :category do
    ikea_id { "MyString" }
    unique_id { 1 }
    name { "MyString" }
    translated_name { "MyString" }
    url { "MyString" }
    remote_image_url { "MyString" }
    local_image_path { "MyString" }
    parent_ids { "MyText" }
    is_deleted { false }
    is_important { false }
    is_popular { false }
  end
end
