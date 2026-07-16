class SendpulseEmailJob < ApplicationJob
  queue_as :default

  # Small pause so chained order emails do not land in the inbox as a burst.
  ORDER_EMAIL_CHAIN_WAIT = Integer(ENV.fetch("ORDER_EMAIL_CHAIN_WAIT_SECONDS", "15")).seconds

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(next_order_email: nil, **payload)
    result = Sendpulse::EmailSender.new.call(**payload, raise_on_error: true)
    unless result.success?
      error = result.error
      raise(error) if error.is_a?(Exception)

      raise StandardError, "SendPulse returned failed result: #{error}"
    end

    enqueue_next_order_email(next_order_email)
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Email job error: #{e.class} #{e.message}")
    raise
  end

  private

  def enqueue_next_order_email(next_order_email)
    return if next_order_email.blank?

    data = next_order_email.with_indifferent_access
    keys = Array(data[:template_keys]).map(&:to_s).reject(&:blank?)
    return if keys.empty? || data[:order_id].blank?

    first, *rest = keys
    PrepareOrderEmailJob.set(wait: ORDER_EMAIL_CHAIN_WAIT).perform_later(
      template_key: first,
      order_id: data[:order_id],
      next_template_keys: rest
    )
  rescue StandardError => e
    # Current email already accepted by SendPulse — do not retry the send.
    Rails.logger.error(
      "[SendPulse] Failed to enqueue next order email after successful send: #{e.class} #{e.message} payload=#{next_order_email.inspect}"
    )
  end
end
