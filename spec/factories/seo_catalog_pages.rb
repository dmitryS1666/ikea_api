FactoryBot.define do
  factory :seo_catalog_page do
    sequence(:slug) { |n| "seo-page-#{n}" }
    title { "SEO page" }
    h1 { "SEO H1" }
    meta_title { "SEO title" }
    meta_description { "SEO description" }
    status { :draft }
    indexable { true }
    filter_config do
      {
        "only_available" => true,
        "sort" => "popular",
        "limit" => 60
      }
    end

    trait :published do
      status { :published }
    end
  end
end
