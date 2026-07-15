# frozen_string_literal: true

require "rails_helper"

RSpec.describe FinanceEntry, type: :model do
  it "creates and updates a financial projection from a finalized order" do
    order = create(:order, total_amount: 145.25, payment_order_number: "INV-42")

    entry = order.reload.finance_entry
    expect(entry).to have_attributes(
      amount: 145.25,
      invoice_number: "INV-42",
      invoice_status: "issued",
      payment_status: "pending"
    )

    order.update!(status: :paid, webpay_transaction_id: "PAY-42", webpay_paid_at: Time.current)

    expect(entry.reload).to have_attributes(payment_reference: "PAY-42", payment_status: "paid")
    expect(entry.paid_at).to be_present
  end

  it "does not create a financial entry for a checkout draft" do
    order = create(:order, checkout_draft: true)

    expect(order.finance_entry).to be_nil
  end

  it "records who reconciled a payment" do
    owner = create(:user, role: "admin")
    entry = create(:order).finance_entry

    Current.set(admin_user: owner) { entry.update!(reconciliation_status: "matched") }

    expect(entry).to have_attributes(reconciled_by: owner)
    expect(entry.reconciled_at).to be_present
  ensure
    Current.reset
  end
end
