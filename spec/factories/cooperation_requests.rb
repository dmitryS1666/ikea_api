# frozen_string_literal: true

FactoryBot.define do
  factory :cooperation_request do
    sequence(:first_name) { |n| "Имя#{n}" }
    sequence(:last_name) { |n| "Фамилия#{n}" }
    name { "#{first_name} #{last_name}" }
    sequence(:email) { |n| "coop#{n}@example.com" }
    phone { "375291234567" }
    city { "Минск" }
    cooperation_type { "dealer" }
    message { "Хочу стать партнёром" }
    comment { message }
    personal_data_consent { true }
    marketing_email_consent { false }
    status { "new" }
  end
end
