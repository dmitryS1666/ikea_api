# frozen_string_literal: true

class SendpulseEmailJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(continue_order_queue: false, order_id: nil, template_key: nil, next_order_email: nil, email_log_id: nil, **payload)
    sender_payload = payload.except(:email_log_id, :template_key, :order_id, :continue_order_queue)
    accepted = false

    begin
      result = Sendpulse::EmailSender.new.call(**sender_payload, raise_on_error: true)
      unless result.success?
        mark_log_failed!(email_log_id, result.error)
        error = result.error
        raise(error) if error.is_a?(Exception)

        raise StandardError, "SendPulse returned failed result: #{error}"
      end

      mark_log_sent!(email_log_id, result.response)
      accepted = true
    rescue StandardError => e
      mark_log_failed!(email_log_id, e) unless accepted
      Rails.logger.error("[SendPulse] Email job error: #{e.class} #{e.message}")
      raise
    end

    advance_order_email_queue(
      continue_order_queue: continue_order_queue,
      order_id: order_id,
      template_key: template_key,
      next_order_email: next_order_email
    )
  end

  private

  def mark_log_sent!(email_log_id, response)
    log = find_log(email_log_id)
    return if log.blank?

    message_id = extract_provider_message_id(response)
    log.mark_sent!(provider_message_id: message_id, response: response)
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Failed to mark email log sent id=#{email_log_id}: #{e.class} #{e.message}")
  end

  def mark_log_failed!(email_log_id, error)
    log = find_log(email_log_id)
    return if log.blank?
    return if log.status.in?(%w[sent delivered opened clicked])

    log.mark_failed!(error: error)
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Failed to mark email log failed id=#{email_log_id}: #{e.class} #{e.message}")
  end

  def find_log(email_log_id)
    return if email_log_id.blank?

    TransactionalEmailLog.find_by(id: email_log_id)
  end

  def extract_provider_message_id(response)
    data = response.is_a?(Hash) ? response.with_indifferent_access : {}
    data[:id].presence || data[:message_id].presence || data.dig(:data, :id)
  end

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
