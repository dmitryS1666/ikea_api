module Sendpulse
  class UnsubscribeHandler
    def self.call(payload)
      email = extract_email(payload)
      return { success: false, error: "email not found in payload" } if email.blank?

      user = User.find_by(email: email)
      return { success: true, skipped: true, reason: "user_not_found" } unless user

      user.update!(
        email_marketing: false,
        newsletter_consent: false
      )

      ConsentService.record!(
        user: user,
        consent_type: :newsletter_email,
        accepted: false,
        source: "unsubscribe_webhook",
        metadata: {
          provider: "sendpulse",
          payload: safe_payload(payload)
        }
      )

      { success: true, user_id: user.id }
    end

    def self.extract_email(payload)
      data = payload.is_a?(Hash) ? payload : {}
      data["email"].presence ||
        data.dig("recipient", "email").presence ||
        data.dig("data", "email").presence
    end
    private_class_method :extract_email

    def self.safe_payload(payload)
      payload.is_a?(Hash) ? payload.slice("event", "email", "recipient", "data") : {}
    end
    private_class_method :safe_payload
  end
end
