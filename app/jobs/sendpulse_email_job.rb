class SendpulseEmailJob < ApplicationJob
  queue_as :default

  retry_on Sendpulse::Error, wait: :exponentially_longer, attempts: 3

  def perform(**payload)
    result = Sendpulse::EmailSender.new.call(**payload, raise_on_error: true)

    unless result.success?
      Rails.logger.error("[SendPulse] Email job finished with failed result: #{result.error}")
    end
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Email job error: #{e.class} #{e.message}")
    raise e if e.is_a?(Sendpulse::Error)
  end
end
