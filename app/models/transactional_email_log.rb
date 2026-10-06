# frozen_string_literal: true

class TransactionalEmailLog < ApplicationRecord
  STATUSES = %w[
    queued
    sent
    failed
    delivered
    undelivered
    opened
    clicked
    soft_bounced
    hard_bounced
    spam
  ].freeze

  TEMPLATE_LABELS = {
    "order_created" => "Заказ в обработке",
    "order_awaiting_payment" => "Ожидает оплаты",
    "order_placed" => "Заказ оформлен",
    "received_poland" => "Склад в Польше",
    "shipped_to_pvz" => "В пути / ПВЗ",
    "order_delivered" => "Заказ доставлен / отзыв",
    "order_cancelled" => "Заказ отменён",
    "abandoned_cart" => "Брошенная корзина",
    "welcome" => "Подтверждение e-mail",
    "email_changed" => "Смена e-mail",
    "admin_order_created" => "Админам: новый заказ"
  }.freeze

  belongs_to :user, optional: true
  belongs_to :order, optional: true

  validates :to_email, :template_key, :subject, :status, :queued_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def template_label
    TEMPLATE_LABELS[template_key.to_s] || template_key.to_s
  end

  def status_label
    I18n.t("activerecord.attributes.transactional_email_log.statuses.#{status}", default: status)
  end

  def mark_sent!(provider_message_id:, response: nil)
    attrs = {
      status: "sent",
      provider_message_id: provider_message_id.presence || self.provider_message_id,
      sent_at: sent_at || Time.current,
      last_event_at: Time.current,
      error_message: nil
    }
    attrs[:metadata] = metadata.merge("send_response" => response) if response.present?
    update!(attrs)
  end

  def mark_failed!(error:)
    update!(
      status: "failed",
      failed_at: Time.current,
      last_event_at: Time.current,
      error_message: error.to_s.truncate(1000)
    )
  end

  def apply_provider_event!(event_name, payload = {})
    event = event_name.to_s
    now = event_time(payload)

    attrs = {
      last_event_at: now,
      metadata: metadata.merge("last_event" => event, "last_event_payload" => payload)
    }

    case event
    when "delivered"
      attrs[:status] = "delivered"
      attrs[:delivered_at] = delivered_at || now
    when "undelivered"
      attrs[:status] = "undelivered"
      attrs[:failed_at] = failed_at || now
      attrs[:error_message] = payload["smtp_server_response"].presence || error_message
    when "opened"
      attrs[:status] = "opened" unless status.in?(%w[clicked])
      attrs[:opened_at] = opened_at || now
      attrs[:delivered_at] ||= now
    when "clicked"
      attrs[:status] = "clicked"
      attrs[:opened_at] ||= now
      attrs[:delivered_at] ||= now
    when "soft_bounces", "soft_bounce"
      attrs[:status] = "soft_bounced"
      attrs[:failed_at] = failed_at || now
      attrs[:error_message] = payload["smtp_server_response"].presence || error_message
    when "hard_bounces", "hard_bounce"
      attrs[:status] = "hard_bounced"
      attrs[:failed_at] = failed_at || now
      attrs[:error_message] = payload["smtp_server_response"].presence || error_message
    when "spam_by_user", "spam"
      attrs[:status] = "spam"
    else
      return false
    end

    update!(attrs)
    true
  end

  private

  def event_time(payload)
    ts = payload["timestamp"].to_i
    return Time.current if ts <= 0

    Time.zone.at(ts)
  rescue ArgumentError, TypeError
    Time.current
  end
end
