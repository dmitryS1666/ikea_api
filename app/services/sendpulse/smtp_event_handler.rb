# frozen_string_literal: true

module Sendpulse
  class SmtpEventHandler
    TRACKED_EVENTS = %w[
      delivered
      undelivered
      opened
      clicked
      soft_bounces
      soft_bounce
      hard_bounces
      hard_bounce
      spam_by_user
      spam
    ].freeze

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = normalize_payload(payload)
    end

    def call
      events = Array(payload)
      results = events.map { |event| process_event(event) }
      {
        success: results.any? { |result| result[:success] },
        processed: results.count { |result| result[:success] },
        results: results
      }
    end

    private

    attr_reader :payload

    def normalize_payload(raw)
      data = raw.is_a?(Hash) ? raw.with_indifferent_access : raw
      return data if data.is_a?(Array)
      return [data] if data.is_a?(Hash)
      []
    end

    def process_event(event)
      data = event.is_a?(Hash) ? event.with_indifferent_access : {}
      name = data[:event].to_s
      return { success: false, ignored: true, event: name.presence || "unknown" } unless TRACKED_EVENTS.include?(name)

      log = find_log(data)
      return { success: false, ignored: true, event: name, reason: "log_not_found" } if log.blank?

      applied = log.apply_provider_event!(name, data)
      { success: applied, event: name, log_id: log.id }
    rescue StandardError => e
      Rails.logger.error("[SendPulse] SMTP event failed: #{e.class} #{e.message}")
      { success: false, error: e.message, event: name }
    end

    def find_log(data)
      message_id = data[:message_id].presence || data[:id].presence
      if message_id.present?
        log = TransactionalEmailLog.find_by(provider_message_id: message_id.to_s)
        return log if log
      end

      recipient = data[:recipient].to_s.downcase.strip
      subject = data[:subject].to_s
      return if recipient.blank?

      scope = TransactionalEmailLog.where("LOWER(to_email) = ?", recipient).order(created_at: :desc)
      scope = scope.where(subject: subject) if subject.present?
      scope.where("created_at >= ?", 14.days.ago).first
    end
  end
end
