# frozen_string_literal: true

# Rendering is performed in a retryable job instead of the checkout request.
# This guarantees that template/rendering failures are retried and that the
# order is reloaded only after the checkout transaction has committed.
class PrepareOrderEmailJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(template_key:, order_id:, abandoned_cart_activity_at: nil, abandoned_cart_queued_at: nil)
    order = Order.includes(:user, order_items: :product).find(order_id)
    key = template_key.to_sym

    if key == :abandoned_cart
      return unless abandoned_cart_still_valid?(
        order,
        activity_at: abandoned_cart_activity_at,
        queued_at: abandoned_cart_queued_at
      )
    elsif order.checkout_draft?
      raise ArgumentError, "cannot email checkout draft order=#{order.id}"
    end

    OrderEmailSnapshotService.capture!(order)

    TransactionalEmailService.send_template(
      key,
      to_email: order.user&.email,
      to_name: order.full_name.presence || order.user&.full_name,
      order: order.reload,
      user: order.user
    )
  rescue StandardError => e
    Rails.logger.error(
      "[TransactionalEmail] Failed to prepare #{template_key} for order=#{order_id}: #{e.class} #{e.message}"
    )
    raise
  end

  private

  def abandoned_cart_still_valid?(order, activity_at:, queued_at:)
    unless order.checkout_draft? && order.status.to_s == "created" && order.user&.email.present?
      return false
    end

    expected_activity_at = parse_time(activity_at)
    return true if expected_activity_at.blank?
    return true if order.updated_at <= expected_activity_at

    reset_abandoned_cart_marker(order, queued_at)
    false
  end

  def reset_abandoned_cart_marker(order, queued_at)
    expected_queued_at = parse_time(queued_at)
    scope = Order.where(id: order.id, checkout_draft: true)
    scope = scope.where(abandoned_cart_email_sent_at: expected_queued_at) if expected_queued_at.present?
    scope.update_all(abandoned_cart_email_sent_at: nil)
  end

  def parse_time(value)
    return value if value.respond_to?(:acts_like_time?) && value.acts_like_time?
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
