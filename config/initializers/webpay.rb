Rails.application.config.x.webpay = ActiveSupport::InheritableOptions.new.tap do |config|
  config.store_id = ENV.fetch('WEBPAY_STORE_ID', '11111111')
  config.secret_key = ENV.fetch('WEBPAY_SECRET_KEY', 'xxxaL8v9AjMPTB7w4bmXDaEcbjMCNqyw')
  config.store_name = ENV.fetch('WEBPAY_STORE_NAME', 'IKEA by Shop')
  config.return_url = ENV.fetch('WEBPAY_RETURN_URL', '')
  config.cancel_url = ENV.fetch('WEBPAY_CANCEL_URL', '')
  # nil = не задано в окружении → WebpayPaymentLinkService подставит {WEBPAY_LINK_BASE_URL}/api/v1/webhooks/webpay
  # пустая строка в .env = явно без notify URL в форме
  config.notify_url = ENV['WEBPAY_NOTIFY_URL']
  config.currency_id = ENV.fetch('WEBPAY_CURRENCY_ID', 'BYN')
  config.language_id = ENV.fetch('WEBPAY_LANGUAGE_ID', 'russian')
  config.version = ENV.fetch('WEBPAY_VERSION', '2')
  config.test_flag = ENV.fetch('WEBPAY_TEST_FLAG', '1')
  config.payment_page_url = ENV.fetch('WEBPAY_PAYMENT_PAGE_URL', 'https://securesandbox.webpay.by/')
  config.link_base_url = ENV.fetch('WEBPAY_LINK_BASE_URL', ENV.fetch('API_BASE_URL', 'http://localhost:3000'))
  # Billing API (get_transaction): https://docs.webpay.by/en/paymentIntegration/cardIntegration/paymentVerification/
  config.billing_api_url = ENV.fetch('WEBPAY_BILLING_API_URL', 'https://sandbox.webpay.by')
  config.billing_username = ENV['WEBPAY_BILLING_USERNAME'].to_s
  config.billing_password = ENV['WEBPAY_BILLING_PASSWORD'].to_s
  # Comma-separated; if blank, IP is not checked (dev/sandbox). Production: 178.163.225.84
  config.notify_trusted_ips = ENV.fetch('WEBPAY_NOTIFY_TRUSTED_IPS', '').split(',').map(&:strip).reject(&:blank?)
end
