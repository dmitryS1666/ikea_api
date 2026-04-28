FactoryBot.define do
  factory :user_pickup_point do
    user
    pickup_point { nil }
    provider { "europost" }
    sequence(:external_id) { |n| "ext-#{n}" }
    city { "Минск" }
    address { "пр-т Пушкина, д. 28" }
    working_hours { "Пн-Вс 10:00-21:00" }
    lat { 53.9123 }
    lng { 27.4567 }
    raw_payload { {} }
    deleted_at { nil }
  end
end
