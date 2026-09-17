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

  it "enqueues awaiting-payment on finalization" do
    described_class.call(order)

    expect(TransactionalEmailService).to have_received(:send_order_emails)
      .with(%i[order_awaiting_payment], order)
      .once
    expect(TransactionalEmailService).not_to have_received(:send_order_email)
  end

  it "enqueues order-created when checkout starts from cart" do
    described_class.notify_checkout_started(order)

    expect(TransactionalEmailService).to have_received(:send_order_email).with(:order_created, order).once
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

  it "sends telegram immediately for ERIP and marks the order unpaid" do
    order.update_columns(payment_method: "erip")
    allow(described_class).to receive(:send_telegram_manager_notification).and_call_original

    described_class.call(order)

    expect(TelegramService).to have_received(:send_message).with(
      a_string_including("Новый заказ №#{order.id}")
        .and(a_string_including("Статус оплаты: <b>не оплачен</b>"))
    )
  end

  it "does not send telegram on finalize for card payment" do
    order.update_columns(payment_method: "card")

    described_class.call(order)

    expect(described_class).not_to have_received(:send_telegram_manager_notification)
  end

  it "sends the new-order telegram after a tracked payment is paid" do
    order.update_columns(
      payment_method: "card",
      status: Order.statuses[:paid],
      webpay_paid_at: Time.current
    )
    allow(described_class).to receive(:send_telegram_manager_notification).and_call_original

    described_class.call(order.reload, status_changed: true)

    expect(TelegramService).to have_received(:send_message).with(
      a_string_including("Новый заказ №#{order.id}")
        .and(a_string_including("Статус оплаты: <b>оплачен</b>"))
    )
  end

  it "does not send a second telegram when an ERIP order is later marked paid" do
    order.update_columns(
      payment_method: "erip",
      status: Order.statuses[:paid]
    )

    described_class.call(order.reload, status_changed: true)

    expect(described_class).not_to have_received(:send_telegram_manager_notification)
  end

  it "does not send the new-order telegram on later fulfillment statuses" do
    order.update_columns(
      payment_method: "card",
      status: Order.statuses[:purchased],
      webpay_paid_at: Time.current
    )

    described_class.call(order.reload, status_changed: true)

    expect(described_class).not_to have_received(:send_telegram_manager_notification)
  end
end
