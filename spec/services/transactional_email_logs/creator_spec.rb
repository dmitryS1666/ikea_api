# frozen_string_literal: true

require "rails_helper"

RSpec.describe TransactionalEmailLogs::Creator do
  it "stores the rendered html alongside a short preview" do
    log = described_class.call(
      template_key: "order_delivered",
      to_email: "client@example.com",
      to_name: "Анна",
      subject: "Ваш заказ доставлен",
      text: "Спасибо за покупку",
      html: "<p>Спасибо за покупку</p>"
    )

    expect(log).to be_persisted
    expect(log.html_body).to eq("<p>Спасибо за покупку</p>")
    expect(log.preview_text).to eq("Спасибо за покупку")
    expect(log.status).to eq("queued")
  end
end
