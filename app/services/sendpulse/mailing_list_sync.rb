module Sendpulse
  class MailingListSync
    def self.subscribe(email:, name: nil)
      list_id = ENV["SENDPULSE_MAILING_LIST_ID"]
      return disabled_result("SENDPULSE_MAILING_LIST_ID is not configured") if list_id.blank?
      return Sendpulse::Result.new(success: false, error: "email is blank") if email.blank?

      client = Sendpulse::Client.new
      payload = {
        emails: [
          {
            email: email,
            variables: { name: name }.compact
          }
        ]
      }

      response = client.post("/addressbooks/#{list_id}/emails", payload)
      Sendpulse::Result.new(success: true, response: response)
    rescue Sendpulse::Error => e
      Rails.logger.error("[SendPulse] Mailing list subscribe failed email=#{email}: #{e.message}")
      Sendpulse::Result.new(success: false, error: e)
    end

    def self.unsubscribe(email:)
      list_id = ENV["SENDPULSE_MAILING_LIST_ID"]
      return disabled_result("SENDPULSE_MAILING_LIST_ID is not configured") if list_id.blank?
      return Sendpulse::Result.new(success: false, error: "email is blank") if email.blank?

      client = Sendpulse::Client.new
      response = client.delete("/addressbooks/#{list_id}/emails", { emails: [email] })
      Sendpulse::Result.new(success: true, response: response)
    rescue Sendpulse::Error => e
      Rails.logger.error("[SendPulse] Mailing list unsubscribe failed email=#{email}: #{e.message}")
      Sendpulse::Result.new(success: false, error: e)
    end

    def self.disabled_result(message)
      Rails.logger.info("[SendPulse] Mailing list sync skipped: #{message}")
      Sendpulse::Result.new(success: false, error: message, skipped: true)
    end
    private_class_method :disabled_result
  end
end
