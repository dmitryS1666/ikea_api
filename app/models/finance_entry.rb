# frozen_string_literal: true

class FinanceEntry < ApplicationRecord
  PAYMENT_STATUSES = %w[pending paid refunded failed].freeze
  INVOICE_STATUSES = %w[not_issued issued cancelled].freeze
  RECONCILIATION_STATUSES = %w[pending matched mismatch].freeze
  PAID_ORDER_STATUSES = %w[
    paid purchased received_poland preparing_for_shipment export_eu customs_poland
    on_border customs_belarus shipped arrived_pvz handed_to_courier
    handed_to_courier_ikeya completed
  ].freeze

  belongs_to :order
  belongs_to :reconciled_by, class_name: "User", optional: true

  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :payment_status, inclusion: { in: PAYMENT_STATUSES }
  validates :invoice_status, inclusion: { in: INVOICE_STATUSES }
  validates :reconciliation_status, inclusion: { in: RECONCILIATION_STATUSES }
  validates :order_id, uniqueness: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :unreconciled, -> { where(reconciliation_status: %w[pending mismatch]) }

  before_save :stamp_reconciliation

  def self.sync_from_order!(order)
    return if order.checkout_draft?

    entry = find_or_initialize_by(order: order)
    entry.amount = (order.total_amount || 0).to_d
    entry.payment_reference = order.webpay_transaction_id.presence || order.payment_order_number
    entry.invoice_number ||= order.payment_order_number.presence
    entry.invoice_status = "issued" if entry.invoice_number.present? && entry.invoice_status == "not_issued"
    entry.payment_status = payment_status_for(order) unless entry.payment_status == "refunded"
    entry.paid_at ||= order.webpay_paid_at || order.purchased_at if entry.payment_status == "paid"
    entry.save!
    entry
  end

  def self.payment_status_for(order)
    return "paid" if order.webpay_paid_at.present? || order.status.in?(PAID_ORDER_STATUSES)
    return "failed" if order.cancelled?

    "pending"
  end
  private_class_method :payment_status_for

  private

  def stamp_reconciliation
    return unless will_save_change_to_reconciliation_status?

    if reconciliation_status == "pending"
      self.reconciled_at = nil
      self.reconciled_by = nil
    else
      self.reconciled_at ||= Time.current
      self.reconciled_by ||= Current.admin_user
    end
  end
end
