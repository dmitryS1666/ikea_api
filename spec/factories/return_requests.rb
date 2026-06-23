# frozen_string_literal: true

FactoryBot.define do
  factory :return_request do
    order
    user { order.user }
    order_number { order.public_uid }
    first_name { "Иван" }
    reason { "damaged" }
    comment { "Упаковка вмята" }
    compensation_type { "refund" }
    status { "new" }
  end
end
