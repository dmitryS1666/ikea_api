require 'digest/md5'

class WebpaySignatureService
  class << self
    # https://docs.webpay.by/en/paymentIntegration/cardIntegration/paymentNotification/
    def notify_signature_valid?(params_hash, secret_key)
      sig = params_hash['wsb_signature'].to_s.downcase
      return false if sig.blank? || secret_key.blank?

      expected = Digest::MD5.hexdigest(notify_signing_payload(params_hash) + secret_key)
      ActiveSupport::SecurityUtils.secure_compare(expected, sig)
    end

    # https://docs.webpay.by/en/paymentIntegration/cardIntegration/paymentVerification/
    def get_transaction_signature_valid?(fields, secret_key)
      sig = fields['wsb_signature'].to_s.downcase
      return true if sig.blank?

      return false if secret_key.blank?

      expected = Digest::MD5.hexdigest(get_transaction_signing_payload(fields) + secret_key)
      ActiveSupport::SecurityUtils.secure_compare(expected, sig)
    end

    private

    def notify_signing_payload(p)
      parts = %w[
        batch_timestamp currency_id amount payment_method order_id site_order_id
        transaction_id payment_type rrn
      ].map { |k| p[k].to_s }
      buf = parts.join
      buf += p['card'].to_s if p['card'].present?
      buf
    end

    def get_transaction_signing_payload(f)
      %w[transaction_id batch_timestamp currency_id amount payment_method payment_type order_id rrn].map { |k| f[k].to_s }.join
    end
  end
end
