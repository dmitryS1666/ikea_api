# frozen_string_literal: true

class SendpulseEmailJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(continue_order_queue: false, order_id: nil, template_key: nil, next_order_email: nil, **payload)
    result = Sendpulse::EmailSender.new.call(**payload, raise_on_error: true)
    unless result.success?
      error = result.error
      raise(error) if error.is_a?(Exception)

      raise StandardError, "SendPulse returned failed result: #{error}"
    end

    advance_order_email_queue(
      continue_order_queue: continue_order_queue,
      order_id: order_id,
      template_key: template_key,
      next_order_email: next_order_email
    )
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Email job error: #{e.class} #{e.message}")
    raise
  end

  private

  def advance_order_email_queue(continue_order_queue:, order_id:, template_key:, next_order_email:)
    if continue_order_queue && order_id.present?
      OrderEmailQueue.complete_and_continue!(order_id, previous_template_key: template_key)
      return
    end

    # Legacy chain payload from older PrepareOrderEmailJob deploys.
    enqueue_legacy_next_order_email(next_order_email)
  end

  def enqueue_legacy_next_order_email(next_order_email)
    return if next_order_email.blank?

    data = next_order_email.with_indifferent_access
    keys = Array(data[:template_keys]).map(&:to_s).reject(&:blank?)
    return if keys.empty? || data[:order_id].blank?

    order = Order.find_by(id: data[:order_id])
    return if order.blank?

    OrderEmailQueue.enqueue!(order, keys)
  rescue StandardError => e
    Rails.logger.error(
      "[SendPulse] Failed to enqueue next order email after successful send: #{e.class} #{e.message} payload=#{next_order_email.inspect}"
    )
  end
end
