# frozen_string_literal: true

Trestle.resource(:finance_entries, model: FinanceEntry) do
  menu do
    item :finance_entries, icon: "fa fa-file-invoice-dollar", group: :finance,
                           label: "Оплаты и счета",
                           if: -> { current_user&.allowed_for_admin_resource?(:finance_entries, :index) }
  end

  routes do
    get :export_registry, on: :collection
  end

  scopes do
    scope :all, default: true
    scope :unreconciled, -> { FinanceEntry.unreconciled }, label: "Требуют сверки"
    scope :paid, -> { FinanceEntry.where(payment_status: "paid") }, label: "Оплачены"
  end

  collection do
    FinanceEntry.includes(:order, :reconciled_by).recent_first
  end

  hook("resource.index.header") do
    if current_user&.allowed_for_admin_resource?(:finance_entries, :export_registry)
      link_to "Скачать Реестр (CSV)", admin.path(:export_registry), class: "btn btn-primary"
    end
  end

  table do
    column :order_id, label: "Заказ", link: true
    column :payment_reference, label: "Платёж"
    column :invoice_number, label: "Счёт"
    column :amount, label: "Сумма" do |entry|
      "#{format('%.2f', entry.amount)} #{entry.currency}"
    end
    column :payment_status, label: "Оплата"
    column :invoice_status, label: "Счёт"
    column :reconciliation_status, label: "Сверка"
    column :paid_at, label: "Оплачено"
    actions do |toolbar, entry, admin_resource|
      toolbar.show
      toolbar.edit if current_user&.has_admin_permission?(:finance_manage) && admin_resource.actions.include?(:edit)
    end
  end

  form do |entry|
    static_field :order, label: "Заказ" do
      "##{entry.order.public_uid} (ID #{entry.order_id})"
    end
    text_field :payment_reference, label: "Платёжный идентификатор"
    text_field :invoice_number, label: "Номер счёта"
    number_field :amount, label: "Сумма", step: 0.01, min: 0
    text_field :currency, label: "Валюта"
    select :payment_status, FinanceEntry::PAYMENT_STATUSES.map { |value| [value, value] }, label: "Статус оплаты"
    select :invoice_status, FinanceEntry::INVOICE_STATUSES.map { |value| [value, value] }, label: "Статус счёта"
    select :reconciliation_status, FinanceEntry::RECONCILIATION_STATUSES.map { |value| [value, value] }, label: "Статус сверки"
    datetime_field :paid_at, label: "Дата оплаты"
    text_area :notes, label: "Примечание", rows: 4
    static_field :reconciled_at, label: "Дата сверки"
    static_field :reconciled_by, label: "Сверил"
  end

  controller do
    def export_registry
      send_data(
        Admin::FinanceRegistryExport.call,
        filename: "finance-registry-#{Date.current.iso8601}.csv",
        type: "text/csv; charset=utf-8",
        disposition: "attachment"
      )
    end
  end

  params do |params|
    params.require(:finance_entry).permit(
      :payment_reference, :invoice_number, :amount, :currency, :payment_status,
      :invoice_status, :reconciliation_status, :paid_at, :notes
    )
  end
end
