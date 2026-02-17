FactoryBot.define do
  factory :seo_metum do
    seoable { nil }
    title { "MyString" }
    description { "MyText" }
    keywords { "MyString" }
    robots { "MyString" }
    seo_text { "MyText" }
  end
end
