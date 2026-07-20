# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendAbandonedCartEmailsJob, type: :job do
  let(:user) do
    create(
      :user,
      email: "customer@example.com",
      email_marketing: true,
      newsletter_consent: true,
      email_verified_at: 1.day.ago
    )
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV)
      .to receive(:fetch)
      .with("ABANDONED_CART_EMAIL_DELAY_MINUTES", "30")
      .and_return("30")

    allow(TransactionalEmailService).to receive(:send_order_email)
  end

  it "queues one abandoned-cart email 30 minutes after the last draft activity" do
    order = abandoned_draft(updated_at: 31.minutes.ago)

    described_class.perform_now
    described_class.perform_now

    expect(TransactionalEmailService).to have_received(:send_order_email).once.with(
      :abandoned_cart,
      order,
      abandoned_cart_activity_at: kind_of(ActiveSupport::TimeWithZone),
      abandoned_cart_queued_at: kind_of(ActiveSupport::TimeWithZone)
    )
    expect(order.reload.abandoned_cart_email_sent_at).to be_present
  end

  it "does not queue the email before 30 minutes of inactivity" do
    order = abandoned_draft(updated_at: 29.minutes.ago)

    described_class.perform_now

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
    expect(order.reload.abandoned_cart_email_sent_at).to be_nil
  end

  it "uses last activity instead of draft creation time" do
    order = abandoned_draft(created_at: 3.hours.ago, updated_at: 5.minutes.ago)

    described_class.perform_now

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
    expect(order.reload.abandoned_cart_email_sent_at).to be_nil
  end

  it "does not queue another mailing when the first one was already queued" do
    order = abandoned_draft(
      updated_at: 2.hours.ago,
      abandoned_cart_email_sent_at: 1.hour.ago
    )

    described_class.perform_now

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
    expect(order.reload.abandoned_cart_email_sent_at).to be_present
  end

  it "does not email finalized orders or users without an email" do
    finalized = abandoned_draft(updated_at: 2.hours.ago)
    finalized.update_columns(checkout_draft: false)

    no_email_user = create(:user, email: nil)
    without_email = abandoned_draft(user: no_email_user, updated_at: 2.hours.ago)

    described_class.perform_now

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
    expect(finalized.reload.abandoned_cart_email_sent_at).to be_nil
    expect(without_email.reload.abandoned_cart_email_sent_at).to be_nil
  end

  it "does not email a user who unsubscribed from marketing" do
    user.update!(email_marketing: false, newsletter_consent: false)
    order = abandoned_draft(updated_at: 2.hours.ago)

    described_class.perform_now

    expect(TransactionalEmailService).not_to have_received(:send_order_email)
    expect(order.reload.abandoned_cart_email_sent_at).to be_nil
  end

  it "releases the one-time marker when enqueueing fails" do
    order = abandoned_draft(updated_at: 31.minutes.ago)
    allow(TransactionalEmailService).to receive(:send_order_email).and_raise("queue unavailable")

    expect { described_class.perform_now }.not_to raise_error

    expect(order.reload.abandoned_cart_email_sent_at).to be_nil
  end

  private

  def abandoned_draft(user: self.user, created_at: 2.hours.ago, updated_at:, abandoned_cart_email_sent_at: nil)
    order = create(
      :order,
      user: user,
      checkout_draft: true,
      status: :created,
      abandoned_cart_email_sent_at: abandoned_cart_email_sent_at
    )
    create(:order_item, order: order, product_sku: "ABANDONED-SKU", quantity: 1, price: 100.0)
    order.update_columns(created_at: created_at, updated_at: updated_at)
    order
  end
end
