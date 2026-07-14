# frozen_string_literal: true

require "base64"
require "uri"

class MarketingUnsubscribeService
  class InvalidToken < StandardError; end

  TOKEN_VERSION = 1
  SUCCESS_MESSAGE = "Вы успешно отписались от рекламной рассылки".freeze
  ALREADY_UNSUBSCRIBED_MESSAGE = "Вы уже отписаны от рекламной рассылки".freeze

  class << self
    def url_for(user)
      base_url = ENV["MARKETING_UNSUBSCRIBE_URL"].presence || "#{Seo::PublicSiteUrl.resolve}/unsubscribe"
      "#{base_url}?#{URI.encode_www_form(token: token_for(user))}"
    end

    def unsubscribe_by_token!(token)
      unsubscribe_user!(
        user_from_token!(token),
        source: "email_unsubscribe_link",
        metadata: { channel: "email" }
      )
    end

    def unsubscribe_user!(user, source:, metadata: {})
      changed = false

      user.with_lock do
        changed = MarketingSubscriptionService.subscribed?(user)

        if changed
          user.update!(email_marketing: false, newsletter_consent: false)
          ConsentService.record!(
            user: user,
            consent_type: :newsletter_email,
            accepted: false,
            source: source,
            metadata: metadata
          )
        end
      end

      if changed
        { success: true, status: "unsubscribed", message: SUCCESS_MESSAGE }
      else
        { success: true, status: "already_unsubscribed", message: ALREADY_UNSUBSCRIBED_MESSAGE }
      end
    end

    private

    def token_for(user)
      raise ArgumentError, "persisted user with email is required" unless user&.persisted? && user.email.present?

      signed = verifier.generate(
        {
          version: TOKEN_VERSION,
          user_id: user.id,
          email: user.email.to_s.downcase
        }
      )
      Base64.urlsafe_encode64(signed, padding: false)
    end

    def user_from_token!(token)
      signed = Base64.urlsafe_decode64(token.to_s)
      payload = verifier.verify(signed).with_indifferent_access

      raise InvalidToken unless payload[:version].to_i == TOKEN_VERSION

      user = User.find_by(id: payload[:user_id])
      unless user&.email.present? && user.email.to_s.casecmp?(payload[:email].to_s)
        raise InvalidToken
      end

      user
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidToken
    end

    def verifier
      Rails.application.message_verifier(:marketing_unsubscribe)
    end
  end
end
