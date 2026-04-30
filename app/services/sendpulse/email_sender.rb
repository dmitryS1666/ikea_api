require "base64"

module Sendpulse
  class EmailSender
    ENDPOINT = "/smtp/emails".freeze

    def initialize(client: Sendpulse::Client.new)
      @client = client
    end

    def call(to_email:, subject:, html:, text: nil, to_name: nil, template_id: nil, variables: {}, raise_on_error: false)
      return Sendpulse::Result.new(success: false, error: "to_email is blank") if to_email.blank?

      payload = build_payload(
        to_email: to_email,
        to_name: to_name,
        subject: subject,
        html: html,
        text: text,
        template_id: template_id,
        variables: variables
      )

      response = @client.post(ENDPOINT, payload)
      Sendpulse::Result.new(success: true, response: response)
    rescue Sendpulse::Error => e
      Rails.logger.error("[SendPulse] Email send failed endpoint=#{ENDPOINT} status=#{e.status} error=#{e.message}")
      raise e if raise_on_error

      Sendpulse::Result.new(success: false, error: e)
    rescue StandardError => e
      Rails.logger.error("[SendPulse] Unexpected email sender error: #{e.class} #{e.message}")
      raise e if raise_on_error

      Sendpulse::Result.new(success: false, error: e)
    end

    private

    def build_payload(to_email:, to_name:, subject:, html:, text:, template_id:, variables:)
      email_payload = {
        subject: subject.to_s,
        from: {
          name: ENV.fetch("SENDPULSE_FROM_NAME", "IKEA"),
          email: ENV["SENDPULSE_FROM_EMAIL"]
        },
        to: [
          {
            name: to_name.presence,
            email: to_email
          }.compact
        ]
      }

      if template_id.present?
        email_payload[:template] = {
          id: template_id,
          variables: variables || {}
        }
      else
        email_payload[:html] = Base64.strict_encode64(html.to_s)
        email_payload[:text] = text if text.present?
      end

      { email: email_payload }
    end
  end
end
