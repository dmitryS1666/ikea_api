# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrderDeliveredReviewEmails::BackfillService do
  let(:user) { create(:user, email: "buyer@example.com") }

  def completed_order_with_item(sku: "SKU-1", **attrs)
    order = create(:order, user: user, status: :completed, checkout_draft: false, **attrs)
    create(:order_item, order: order, product_sku: sku, quantity: 1)
    order
  end

  before do
    allow(TransactionalEmailService).to receive(:send_order_email)
  end

  it "dry-runs completed orders with reviewable items" do
    order = completed_order_with_item

    result = described_class.call(dry_run: true)

    expect(result.dry_run).to eq(true)
    expect(result.candidates).to eq(1)
    expect(result.enqueued).to eq(0)
    expect(result.order_ids).to eq([order.id])
    expect(TransactionalEmailService).not_to have_received(:send_order_email)
  end

  it "enqueues review emails when RUN mode is enabled" do
    order = completed_order_with_item

    result = described_class.call(dry_run: false)

    expect(result.enqueued).to eq(1)
    expect(TransactionalEmailService).to have_received(:send_order_email).with(:order_delivered, order)
  end

  it "skips orders without reviewable items" do
    order = completed_order_with_item(sku: "SKU-REVIEWED")
    create(:review, user: user, product_sku: "SKU-REVIEWED", order: order)

    result = described_class.call(dry_run: true)

    expect(result.candidates).to eq(0)
    expect(result.skipped_no_reviewable_items).to eq(1)
  end

  it "skips orders that already received the email" do
    completed_order_with_item(order_delivered_email_sent_at: 1.day.ago)

    result = described_class.call(dry_run: true)

    expect(result.candidates).to eq(0)
  end
end
