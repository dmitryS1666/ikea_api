# frozen_string_literal: true

# Normalize WebPay return URL at boot so wsb_return_url always targets Rails (under /api or /payment).
module WebpayReturnUrl
  module_function

  def normalize(url, api_base:)
    raw = url.to_s.strip
    api = api_payment_success_url(api_base)
    return api if raw.blank?
    return api if storefront_payment_success_path?(raw) && api.present?

    raw
  end

  def api_payment_success_url(api_base)
    base = api_base.to_s.strip.chomp('/')
    return nil if base.blank?

    "#{base}/api/v1/payment/success"
  end

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
