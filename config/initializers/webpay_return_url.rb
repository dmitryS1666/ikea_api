# frozen_string_literal: true

# Normalize WebPay return URL at boot so wsb_return_url always targets Rails.
#
# WebPay returns only browser parameters (wsb_order_num/wsb_tid), so the safe
# place for wsb_return_url is the backend handler. The storefront redirect is a
# separate setting: WEBPAY_SUCCESS_REDIRECT_URL.
module WebpayReturnUrl
  module_function

  def normalize(url, api_base:)
    api = api_payment_success_url(api_base)
    return api if api.blank?

    raw = url.to_s.strip
    return api if raw.blank?
    return api if api_payment_success_url?(raw)

    Rails.logger.warn(
      "[WebPay] WEBPAY_RETURN_URL=#{raw.inspect} points outside API success handler; " \
      "using #{api.inspect} instead. Set WEBPAY_SUCCESS_REDIRECT_URL for the storefront page."
    ) if defined?(Rails)

    api
  end

  def api_payment_success_url(api_base)
    base = api_base.to_s.strip.chomp('/')
    return nil if base.blank?

    "#{base}/api/v1/payment/success"
  end

  def api_payment_success_url?(url)
    uri = URI.parse(url)
    uri.path.to_s.delete_suffix('/').casecmp?('/api/v1/payment/success')
  rescue URI::InvalidURIError
    false
  end

  # Kept for backwards compatibility with old specs/extensions.
  def storefront_payment_success_path?(url)
    uri = URI.parse(url)
    uri.path.to_s.delete_suffix('/').casecmp?('/payment/success')
  rescue URI::InvalidURIError
    false
  end
end

Rails.application.config.after_initialize do
  cfg = Rails.application.config.x.webpay
  api_base = cfg.link_base_url
  cfg.return_url = WebpayReturnUrl.normalize(cfg.return_url, api_base: api_base)
end
