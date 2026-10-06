# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sendpulse::SmtpEventHandler do
  let!(:log) do
    create(
      :transactional_email_log,
      to_email: "buyer@example.com",
      subject: "Ваш заказ доставлен",
      status: "sent",
      provider_message_id: "pzkic9-0afezp-fc",
      sent_at: 1.minute.ago
    )
  end

  it "marks a log as delivered by provider message id" do
    result = described_class.call(
      [
        {
          "event" => "delivered",
          "message_id" => "pzkic9-0afezp-fc",
          "recipient" => "buyer@example.com",
          "subject" => "Ваш заказ доставлен",
          "timestamp" => Time.current.to_i
        }
      ]
    )

    expect(result[:success]).to eq(true)
    expect(log.reload.status).to eq("delivered")
    expect(log.delivered_at).to be_present
  end

  it "falls back to recipient and subject when message id differs" do
    result = described_class.call(
      "event" => "opened",
      "message_id" => "1149317311",
      "recipient" => "buyer@example.com",
      "subject" => "Ваш заказ доставлен",
      "timestamp" => Time.current.to_i
    )

    expect(result[:success]).to eq(true)
    expect(log.reload.status).to eq("opened")
    expect(log.opened_at).to be_present
  end
end
