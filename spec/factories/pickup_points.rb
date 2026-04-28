FactoryBot.define do
  factory :pickup_point do
    provider { "europost" }
    sequence(:name) { |n| "Pickup Point #{n}" }
    city { "Minsk" }
    address { "Some street, 1" }
    active { true }
    priority { false }
    max_weight_kg { 30.0 }
    max_volume_m3 { 0.3 }
  end
end
