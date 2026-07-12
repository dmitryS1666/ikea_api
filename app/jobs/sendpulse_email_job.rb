class SendpulseEmailJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :exponentially_longer, attempts: 5

  def perform(**payload)
    result = Sendpulse::EmailSender.new.call(**payload, raise_on_error: true)
    return if result.success?

    error = result.error
    raise(error) if error.is_a?(Exception)

    raise StandardError, "SendPulse returned failed result: #{error}"
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Email job error: #{e.class} #{e.message}")
    raise
  end
end
