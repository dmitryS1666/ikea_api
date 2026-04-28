FactoryBot.define do
  factory :user_delivery_address do
    user
    city { "Минск" }
    street { "Победителей" }
    house { "10" }
    building { "1" }
    apartment { "25" }
    entrance { "2" }
    floor { "5" }
    has_elevator { true }
    intercom { "125B" }
    is_private_house { false }
    lat { 53.9045 }
    lng { 27.5615 }
    comment { "Позвонить за 15 минут" }
    deleted_at { nil }
  end
end
