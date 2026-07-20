class Order < ApplicationRecord
  include RequestWorkflowTrackable

  DEFAULT_PAYMENT_TIMEOUT_MINUTES = 20

  def self.payment_timeout
    ENV.fetch("PAYMENT_TIMEOUT_MINUTES", DEFAULT_PAYMENT_TIMEOUT_MINUTES).to_i.minutes
  end

  belongs_to :user, optional: true
  belongs_to :promo_code, optional: true
  has_many :order_items, dependent: :destroy
  has_many :order_status_events, dependent: :destroy
  has_many :return_requests, dependent: :destroy
  has_many :reviews, dependent: :nullify
  has_many :consent_records, dependent: :nullify
  has_one :finance_entry, dependent: :destroy

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
    handed_to_courier: 83329530, # Выдано курьеру Европочта (Выдано курьеру Европочта)
    handed_to_courier_ikeya: 85543826, # Выдано курьеру IKEYA
    completed: 142,            # Успешно реализовано (Доставлено)
    cancelled: 143             # Закрыто и не реализовано (Отменен)
  }

  PURCHASED_STATUSES = %w[arrived_pvz handed_to_courier handed_to_courier_ikeya completed].freeze
  PAYMENT_AUTOCANCEL_STATUSES = %w[created processing].freeze
  DEFAULT_PAYMENT_AUTOCANCEL_GRACE_PERIOD_MINUTES = 0

  FRONTEND_STATUS_ALIASES = {
    "completed" => "delivered",
    "cancelled" => "canceled"
  }.freeze
  PVZ_DELIVERY_TYPES = %w[europost_pickup pickup].freeze
  EUROPOST_TRACKING_VISIBLE_STATUSES_BY_DELIVERY_TYPE = {
    DeliveryTypeNormalizer::EUROPOST_PICKUP => %w[
      customs_belarus
      shipped
      arrived_pvz
      handed_to_courier
      completed
    ].freeze,
    "pickup" => %w[
      customs_belarus
      shipped
      arrived_pvz
      handed_to_courier
      completed
    ].freeze,
    DeliveryTypeNormalizer::COURIER => %w[
      customs_belarus
      shipped
      arrived_pvz
      handed_to_courier
      completed
    ].freeze
  }.freeze
  COURIER_TIMELINE_STATUSES = %w[handed_to_courier handed_to_courier_ikeya].freeze

  scope :purchased, -> { where(status: PURCHASED_STATUSES) }
  scope :expired_unpaid_for_autocancel, lambda { |cutoff_time = Time.current|
    where(status: PAYMENT_AUTOCANCEL_STATUSES, checkout_draft: false)
      .where.not(payment_expires_at: nil)
      .where("payment_expires_at < ?", cutoff_time)
  }
  scope :visible_in_account_list, lambda {
    cutoff = checkout_draft_stale_cutoff
    where(<<~SQL.squish, statuses[:cancelled], statuses[:created], cutoff)
      NOT (
        (checkout_draft = TRUE AND status = ?)
        OR
        (checkout_draft = TRUE AND status = ? AND created_at < ?)
      )
    SQL
  }

  def self.checkout_draft_stale_hours
    ENV.fetch("CHECKOUT_DRAFT_STALE_HOURS", "24").to_i
  end

  def self.checkout_draft_stale_cutoff
    checkout_draft_stale_hours.hours.ago
  end


  PUBLIC_UID_FORMAT = /\A\d{6,8}\z/.freeze

  validates :public_uid, presence: true, uniqueness: true, format: { with: PUBLIC_UID_FORMAT }

  before_validation :ensure_public_uid, on: :create
  before_save :set_purchased_at
  before_create :set_payment_expiration

  after_save :enqueue_tracking_update, if: :saved_change_to_track_number?
  after_create_commit :record_initial_status_event
  after_update_commit :notify_status_change, if: :saved_change_to_status?
  after_update_commit :record_status_change_event, if: :saved_change_to_status?
  after_create_commit :sync_with_crm, if: :persist_non_draft_for_crm?
  after_update_commit :sync_with_crm_after_draft_finalized
  # Финансовая проекция является частью целостности заказа, поэтому создаём её
  # в той же транзакции. after_commit не выполняется до конца transactional
  # RSpec-примера и оставляет временное окно без FinanceEntry на production.
  after_create :sync_finance_entry
  after_update :sync_finance_entry, if: :finance_data_changed?

  def purchased?
    status.in?(PURCHASED_STATUSES)
  end

  def frontend_status
    frontend_status_for(status, delivery_type: delivery_type)
  end

  def frontend_status_title(status_code = status)
    frontend_code = frontend_status_for(
      status_code,
      delivery_type: status_code.to_s == status.to_s ? delivery_type : nil
    )

    frontend_status_title_for(status_code, frontend_code)
  end

  def customer_track_number
    return nil unless customer_tracking_visible?

    resolved_track_number
  end

  def customer_tracking_info
    return nil unless customer_tracking_visible?

    tracking_info
  end

  # Фактический номер Европочты: колонка или сохранённый ответ europost_create.
  def resolved_track_number
    return track_number if track_number.present?

    europost_create = tracking_info.is_a?(Hash) ? tracking_info["europost_create"] : nil
    return nil unless europost_create.is_a?(Hash)

    europost_create["track_number"].presence ||
      europost_create.dig("response", "number").presence
  end

  # ЛК: в URL можно передавать public_uid (6–8 цифр) или числовой id (как раньше).
  def self.find_for_account!(user, id_or_uid)
    s = id_or_uid.to_s.strip
    order =
      if s.match?(PUBLIC_UID_FORMAT)
        user.orders.find_by(public_uid: s) || user.orders.find_by(id: s)
      else
        user.orders.find_by(id: s)
      end
    order || raise(ActiveRecord::RecordNotFound, "Couldn't find Order")
  end

  def self.generate_unique_public_uid
    loop do
      uid = random_public_uid_digit_string
      break uid unless exists?(public_uid: uid)
    end
  end

  def self.random_public_uid_digit_string
    n = rand(6..8)
    rand((10**(n - 1))..((10**n) - 1)).to_s
  end

  def self.payment_autocancel_grace_period
    ENV.fetch(
      "PAYMENT_AUTOCANCEL_GRACE_PERIOD_MINUTES",
      DEFAULT_PAYMENT_AUTOCANCEL_GRACE_PERIOD_MINUTES
    ).to_i.minutes
  end

  def self.cancel_expired_unpaid!(now: Time.current, grace_period: payment_autocancel_grace_period)
    cancel_expired_unpaid_for_relation!(all, now: now, grace_period: grace_period)
  end

  def self.cancel_expired_unpaid_for_relation!(relation, now: Time.current, grace_period: payment_autocancel_grace_period)
    cutoff_time = now - grace_period
    checked = 0
    cancelled = 0

    relation.merge(expired_unpaid_for_autocancel(cutoff_time)).find_each do |order|
      checked += 1
      cancelled += 1 if order.cancel_expired_unpaid!(cutoff_time: cutoff_time)
    end

    { checked: checked, cancelled: cancelled, cutoff_time: cutoff_time }
  end

  def payment_expired?
    payment_expires_at.present? && payment_expires_at < Time.current
  end

  def cancel_expired_unpaid!(cutoff_time: Time.current)
    with_lock do
      reload
      return false unless expired_unpaid_for_autocancel?(cutoff_time: cutoff_time)

      self.status_changed_at = Time.current
      self.status_change_source = "payment_timer"
      update!(
        status: :cancelled,
        cancellation_reason: cancellation_reason.presence || "Истек срок оплаты заказа"
      )
    end

    true
  end

  def expired_unpaid_for_autocancel?(cutoff_time: Time.current)
    !checkout_draft? &&
      status.in?(PAYMENT_AUTOCANCEL_STATUSES) &&
      payment_expires_at.present? &&
      payment_expires_at < cutoff_time
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
      handed_to_courier_ikeya
      completed
      cancelled
    ]

    event_times = order_status_events.ordered.each_with_object({}) do |event, memo|
      memo[event.to_status.to_s] = event.changed_at
    end
    event_times["created"] ||= created_at

    sequence.map do |code|
      applicable = timeline_status_applicable?(code)
      at = applicable ? event_times[code] : nil
      frontend_code = frontend_status_for(code, delivery_type: delivery_type)
      {
        code: frontend_code,
        title: frontend_status_title_for(code, frontend_code),
        at: at&.iso8601,
        is_current: applicable && status.to_s == code,
        is_completed: applicable && at.present?
      }
    end
  end

  private

  def frontend_status_for(status_code, delivery_type: nil)
    return "in_transit_pvz" if status_code.to_s == "shipped" && pvz_delivery_type?(delivery_type)

    FRONTEND_STATUS_ALIASES.fetch(status_code.to_s, status_code.to_s)
  end

  def frontend_status_title_for(status_code, frontend_code)
    I18n.t(
      "activerecord.attributes.order.frontend_statuses.#{frontend_code}",
      default: I18n.t(
        "activerecord.attributes.order.statuses.#{status_code}",
        default: frontend_code.to_s.humanize
      )
    )
  end

  def pvz_delivery_type?(value)
    PVZ_DELIVERY_TYPES.include?(value.to_s)
  end

  # Courier-ветки взаимоисключающие: Европочта vs IKEYA.
  def timeline_status_applicable?(code)
    return true unless COURIER_TIMELINE_STATUSES.include?(code.to_s)

    normalized = DeliveryTypeNormalizer.normalize(delivery_type)
    case code.to_s
    when "handed_to_courier_ikeya"
      normalized == DeliveryTypeNormalizer::IKEYA_DELIVERY
    when "handed_to_courier"
      normalized != DeliveryTypeNormalizer::IKEYA_DELIVERY
    else
      true
    end
  end

  def customer_tracking_visible?
    return false if status.to_s == "handed_to_courier_ikeya"

    normalized_delivery_type = DeliveryTypeNormalizer.normalize(delivery_type)
    return false if normalized_delivery_type == DeliveryTypeNormalizer::IKEYA_DELIVERY
    return false unless resolved_track_number.present?

    visible_statuses = EUROPOST_TRACKING_VISIBLE_STATUSES_BY_DELIVERY_TYPE[normalized_delivery_type]
    visible_statuses.present? && status.to_s.in?(visible_statuses)
  end

  def ensure_public_uid
    self.public_uid = self.class.generate_unique_public_uid if public_uid.blank?
  end

  def set_payment_expiration
    return if checkout_draft

    self.payment_expires_at = self.class.payment_timeout.from_now
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

  def finance_data_changed?
    (saved_changes.keys & %w[
      checkout_draft total_amount status webpay_transaction_id webpay_paid_at
      payment_order_number purchased_at
    ]).any?
  end

  def sync_finance_entry
    FinanceEntry.sync_from_order!(self)
  end
end
