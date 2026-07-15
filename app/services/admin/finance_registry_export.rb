# frozen_string_literal: true

require "csv"

module Admin
  class FinanceRegistryExport
    HEADERS = [
      "ID заказа",
      "Номер заказа",
      "Дата заказа",
      "Платёжный идентификатор",
      "Номер счёта",
      "Сумма",
      "Валюта",
      "Статус оплаты",
      "Статус счёта",
      "Статус сверки",
      "Оплачено",
      "Сверено"
    ].freeze

    def self.call(scope = FinanceEntry.all)
      csv = CSV.generate(col_sep: ";", force_quotes: true) do |output|
        output << HEADERS
        scope.includes(:order).order(created_at: :asc, id: :asc).find_each do |entry|
          output << [
            entry.order_id,
            entry.order.public_uid,
            entry.order.created_at&.iso8601,
            entry.payment_reference,
            entry.invoice_number,
            format("%.2f", entry.amount),
            entry.currency,
            entry.payment_status,
            entry.invoice_status,
            entry.reconciliation_status,
            entry.paid_at&.iso8601,
            entry.reconciled_at&.iso8601
          ]
        end
      end

      "\uFEFF#{csv}"
    end
  end
end
