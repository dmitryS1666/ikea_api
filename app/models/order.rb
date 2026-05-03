class Order < ApplicationRecord
  belongs_to :user
  belongs_to :promo_code, optional: true
  has_many :order_items, dependent: :destroy
  has_many :order_status_events, dependent: :destroy

  attr_accessor :status_changed_at, :status_change_source, :status_change_raw_payload

  # Electronic receipts (PDF) can be attached locally.
  # CRM integration is skipped, so receipts can be uploaded by admin and shown to user.
  has_many_attached :receipts

  enum status: {
    created: 81585318,         # Новый (Новый)
    processing: 81585322,      # В обработке (В работе)
    confirmed: 81585326,       # Заказ подтвержден (Подтвержден)
    paid: 83329494,            # Оплачен (Оплачен)
    purchased: 83329498,       # Ожидается (Выкуплен)
    received_poland: 83329502, # Получен на склад (Получен на склад)
    preparing_for_shipment: 84842138, # Подготовка к отправке
    export_eu: 83329506,       # Реестр (Экспорт из ЕС)
    customs_poland: 83329510,  # ТАМОЖНЯ ПОЛЬШИ (Экспорт из ЕС)
    on_border: 83329514,       # ПРОХОД ГРАНИЦЫ (На границе)
    customs_belarus: 83329518, # ТАМОЖНЯ БЕЛАРУСЬ (Прибыл на таможню)
    shipped: 83329522,         # ПЕРЕДАНО В ЕВРОПОЧТА (Передано в доставку)
    arrived_pvz: 83329526,     # Прибыло в отделение (Прибыло в отделение)
    handed_to_courier: 83329530, # Выдано курьеру (Выдано курьеру)
    completed: 142,            # Успешно реализовано (Доставлено)
    cancelled: 143             # Закрыто и не реализовано (Отменен)
  }

  PURCHASED_STATUSES = %w[arrived_pvz handed_to_courier completed].freeze

  scope :purchased, -> { where(status: PURCHASED_STATUSES) }

  before_save :set_purchased_at
  before_create :set_payment_expiration

  after_update :notify_status_change, if: :saved_change_to_status?
  after_save :enqueue_tracking_update, if: :saved_change_to_track_number?
  after_create_commit :record_initial_status_event
  after_update_commit :record_status_change_event, if: :saved_change_to_status?
  after_create_commit :sync_with_crm, if: :persist_non_draft_for_crm?
  after_update_commit :sync_with_crm_after_draft_finalized

  def purchased?
    status.in?(PURCHASED_STATUSES)
  end

  def payment_expired?
    return false if checkout_draft

    created? && payment_expires_at.present? && Time.current > payment_expires_at
  end

  def customer_name
    user&.full_name || full_name.presence || "—"
  end

  def status_timeline
    sequence = %w[
      created
      processing
      confirmed
      paid
      purchased
      received_poland
      preparing_for_shipment
      export_eu
      customs_poland
      on_border
      customs_belarus
      shipped
      arrived_pvz
      handed_to_courier
      completed
      cancelled
    ]

    event_times = order_status_events.ordered.each_with_object({}) do |event, memo|
      memo[event.to_status.to_s] = event.changed_at
    end
    event_times["created"] ||= created_at

    sequence.map do |code|
      at = event_times[code]
      {
        code: code,
        title: I18n.t("activerecord.attributes.order.statuses.#{code}", default: code.humanize),
        at: at&.iso8601,
        is_current: status.to_s == code,
        is_completed: at.present?
      }
    end
  end

  private

  def set_payment_expiration
    return if checkout_draft

    self.payment_expires_at = 30.minutes.from_now
    # self.payment_url = "https://payment-gateway.com/pay/#{SecureRandom.hex(10)}"
  end

  def enqueue_tracking_update
    UpdateOrderTrackingInfoJob.perform_later(id) if track_number.present?
  end

  def notify_status_change
    OrderNotificationService.call(self, status_changed: true)
  end

  def record_initial_status_event
    order_status_events.create!(
      from_status: nil,
      to_status: status.to_s,
      changed_at: created_at || Time.current,
      source: "system"
    )
  end

  def record_status_change_event
    from_status, to_status = saved_change_to_status
    return if to_status.blank?

    changed_at = status_changed_at.presence || Time.current
    source = status_change_source.presence || "system"

    order_status_events.create!(
      from_status: from_status.to_s.presence,
      to_status: to_status.to_s,
      changed_at: changed_at,
      source: source,
      raw_payload: status_change_raw_payload.is_a?(Hash) ? status_change_raw_payload : {}
    )
  ensure
    self.status_changed_at = nil
    self.status_change_source = nil
    self.status_change_raw_payload = nil
  end

  def set_purchased_at
    return unless transitioning_to_purchased?

    self.purchased_at ||= Time.current
  end

  def transitioning_to_purchased?
    will_save_change_to_status? && status.in?(PURCHASED_STATUSES)
  end

  def sync_with_crm
    CrmSyncJob.perform_later('Order', id)
  end

  def persist_non_draft_for_crm?
    !checkout_draft
  end

  def sync_with_crm_after_draft_finalized
    change = saved_changes['checkout_draft']
    return unless change&.first == true && change&.last == false

    CrmSyncJob.perform_later('Order', id)
  end
end
