class Order < ApplicationRecord
  belongs_to :user
  belongs_to :promo_code, optional: true
  has_many :order_items, dependent: :destroy

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

  def purchased?
    status.in?(PURCHASED_STATUSES)
  end

  def payment_expired?
    created? && payment_expires_at.present? && Time.current > payment_expires_at
  end

  def customer_name
    user&.full_name || full_name.presence || "—"
  end

  private

  def set_payment_expiration
    self.payment_expires_at = 30.minutes.from_now
    # self.payment_url = "https://payment-gateway.com/pay/#{SecureRandom.hex(10)}"
  end

  def enqueue_tracking_update
    UpdateOrderTrackingInfoJob.perform_later(id) if track_number.present?
  end

  def notify_status_change
    OrderNotificationService.call(self, status_changed: true)
  end

  def set_purchased_at
    return unless transitioning_to_purchased?

    self.purchased_at ||= Time.current
  end

  def transitioning_to_purchased?
    will_save_change_to_status? && status.in?(PURCHASED_STATUSES)
  end
end
