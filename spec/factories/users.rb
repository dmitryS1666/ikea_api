FactoryBot.define do
  factory :user do
    sequence(:username) { |n| "user#{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password" }
    phone { "37529#{rand(1000000..9999999)}" }
    role { "user" }
    is_active { true }
  end
end
