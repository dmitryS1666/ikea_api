# frozen_string_literal: true

require "rails_helper"

RSpec.describe TransactionalEmailLogs::Preview do
  let(:user) { create(:user, email: "client@example.com", first_name: "Анна") }
  let(:order) { create(:order, user: user, public_uid: "3159412") }

  it "prefers the html saved at send time" do
    log = create(:transactional_email_log, user: user, order: order, html_body: "<p>Как ушло</p>")

    result = described_class.call(log)

    expect(result.source).to eq(:stored)
    expect(result.html).to eq("<p>Как ушло</p>")
  end

  it "rebuilds an order email from the current template when html was not stored" do
    log = create(:transactional_email_log, user: user, order: order, template_key: "order_placed", html_body: nil)
    allow(EmailTemplates::Renderer).to receive(:render).and_return("<p>Собрано заново</p>")

    result = described_class.call(log)

    expect(result.source).to eq(:rebuilt)
    expect(result.html).to eq("<p>Собрано заново</p>")
    expect(EmailTemplates::Renderer).to have_received(:render).with(:order_placed, hash_including(order: order, user: user))
  end

  it "rebuilds the admin new-order letter from the order" do
    log = create(
      :transactional_email_log,
      user: user,
      order: order,
      template_key: "admin_order_created",
      html_body: nil
    )
    allow(OrderNotificationService).to receive(:build_admin_order_created_html).and_return("<h2>Новый заказ</h2>")

    result = described_class.call(log)

    expect(result.source).to eq(:rebuilt)
    expect(result.html).to include("Новый заказ")
  end

  it "returns no html when the letter cannot be reconstructed" do
    log = create(
      :transactional_email_log,
      user: nil,
      order: nil,
      to_email: "client@example.com",
      template_key: "welcome",
      html_body: nil
    )

    result = described_class.call(log)

    expect(result.source).to eq(:missing)
    expect(result.html).to be_nil
  end
end
