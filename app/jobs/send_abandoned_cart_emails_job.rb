# frozen_string_literal: true

class SendAbandonedCartEmailsJob < ApplicationJob
  queue_as :default

  DEFAULT_DELAY_MINUTES = 30

  def perform
    cutoff = delay_minutes.minutes.ago

    eligible_orders(cutoff).find_each do |order|
      enqueue_once(order, cutoff)
    end
  end

  private

  def delay_minutes
    value = ENV.fetch("ABANDONED_CART_EMAIL_DELAY_MINUTES", DEFAULT_DELAY_MINUTES.to_s).to_i
    value.positive? ? value : DEFAULT_DELAY_MINUTES
  end

  def eligible_orders(cutoff)
    Order
      .where(checkout_draft: true, status: Order.statuses[:created])
      .where(abandoned_cart_email_sent_at: nil)
      .where("orders.updated_at <= ?", cutoff)
      .joins(:user)
      .where.not(users: { email: [nil, ""] })
      .where.not(users: { email_verified_at: nil })
      .where("users.email_marketing IS TRUE OR users.newsletter_consent IS TRUE")
      .includes(:user, order_items: :product)
  end

  def enqueue_once(order, cutoff)
    queued_at = nil
    activity_at = nil

    order.with_lock do
      order.reload
      return unless eligible_now?(order, cutoff)

      activity_at = order.updated_at
      queued_at = Time.current
      order.update_columns(abandoned_cart_email_sent_at: queued_at)
    end

    TransactionalEmailService.send_order_email(
      :abandoned_cart,
      order,
      abandoned_cart_activity_at: activity_at,
      abandoned_cart_queued_at: queued_at
    )
  rescue StandardError => e
    reset_queue_marker(order, queued_at)
    Rails.logger.error(
      "[AbandonedCart] Failed to enqueue order=#{order.id}: #{e.class} #{e.message}"
    )
  end

  def eligible_now?(order, cutoff)
    order.checkout_draft? &&
      order.status.to_s == "created" &&
      order.abandoned_cart_email_sent_at.nil? &&
      order.updated_at <= cutoff &&
      order.user&.email.present? &&
      MarketingSubscriptionService.subscribed?(order.user)
  end

  def reset_queue_marker(order, queued_at)
    return if queued_at.blank?

    Order
      .where(id: order.id, checkout_draft: true, abandoned_cart_email_sent_at: queued_at)
      .update_all(abandoned_cart_email_sent_at: nil)
  end
end
