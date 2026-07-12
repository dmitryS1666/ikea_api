# frozen_string_literal: true

require "base64"

class OrderReorderLinkService
  EXPIRES_IN = 30.days

  class << self
    def url_for(order)
      signed = verifier.generate(
        { order_id: order.id, user_id: order.user_id },
        expires_in: EXPIRES_IN
      )
      token = Base64.urlsafe_encode64(signed, padding: false)
      "#{api_base_url}/api/v1/order_reorders/#{token}"
    end

    def order_from_token!(token)
      signed = Base64.urlsafe_decode64(token.to_s)
      payload = verifier.verify(signed).with_indifferent_access
      order = Order.find(payload.fetch(:order_id))

      unless order.user_id.present? && order.user_id == payload[:user_id].to_i
        raise ActiveSupport::MessageVerifier::InvalidSignature, "order owner mismatch"
      end
      unless order.cancelled?
        raise ActiveSupport::MessageVerifier::InvalidSignature, "order is not cancelled"
      end

      order
    rescue ArgumentError
      raise ActiveSupport::MessageVerifier::InvalidSignature, "invalid reorder token"
    end

    private

    def api_base_url
      ENV["API_BASE_URL"].presence&.chomp("/") || Seo::PublicSiteUrl.resolve
    end

    def verifier
      Rails.application.message_verifier(:order_reorder)
    end
  end
end
