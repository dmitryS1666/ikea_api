# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrderNotificationService do
  let(:user) { create(:user, email: "customer@example.com") }
  let(:order) { create(:order, user: user, checkout_draft: false, status: :processing) }

  before do
    allow(TransactionalEmailService).to receive(:send_order_email)
    allow(TransactionalEmailService).to receive(:send_order_emails)
    allow(TelegramService).to receive(:send_message)
    allow(described_class).to receive(:enqueue_admin_order_created_email)
    allow(described_class).to receive(:send_telegram_manager_notification)
  end

  it "enqueues order-created and awaiting-payment emails as a sequential chain after finalization" do
    described_class.call(order)

    expect(TransactionalEmailService).to have_received(:send_order_emails)
      .with(%i[order_created order_awaiting_payment], order)
      .once
    expect(TransactionalEmailService).not_to have_received(:send_order_email)
  end

  it "does not rebuild the cart automatically when an order is cancelled" do
    allow(OrderReorderService).to receive(:call)
    order.update_column(:status, Order.statuses[:cancelled])

    described_class.call(order.reload, status_changed: true)

    expect(OrderReorderService).not_to have_received(:call)
    expect(TransactionalEmailService).to have_received(:send_order_email).with(:order_cancelled, order)
  end

  it "does not send the PVZ template for courier delivery" do
    order.update_columns(
      status: Order.statuses[:shipped],
      delivery_type: DeliveryTypeNormalizer::COURIER
    )

    described_class.call(order.reload, status_changed: true)

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
  end
end
