# frozen_string_literal: true

FactoryBot.define do
  factory :transactional_email_log do
    user
    order { association :order, user: user }
    to_email { user.email.presence || "client@example.com" }
    to_name { "Анна" }
    template_key { "order_delivered" }
    subject { "Ваш заказ доставлен" }
    preview_text { "Спасибо, что выбрали IKEYA. Оцените покупку." }
    status { "queued" }
    provider { "sendpulse" }
    queued_at { Time.current }
    last_event_at { Time.current }
    metadata { {} }
  end
end
