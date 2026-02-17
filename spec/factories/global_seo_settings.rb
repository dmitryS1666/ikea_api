FactoryBot.define do
  factory :global_seo_setting do
    target_type { "MyString" }
    title_template { "MyString" }
    description_template { "MyString" }
    keywords_template { "MyString" }
    robots { "MyString" }
    seo_text { "MyText" }
  end
end
