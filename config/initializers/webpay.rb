Rails.application.config.x.webpay = ActiveSupport::InheritableOptions.new.tap do |config|
  config.store_id = ENV.fetch('WEBPAY_STORE_ID', '11111111')
  config.secret_key = ENV.fetch('WEBPAY_SECRET_KEY', 'xxxaL8v9AjMPTB7w4bmXDaEcbjMCNqyw')
  config.store_name = ENV.fetch('WEBPAY_STORE_NAME', 'IKEA by Shop')
  config.return_url = ENV.fetch('WEBPAY_RETURN_URL', '')
  config.cancel_url = ENV.fetch('WEBPAY_CANCEL_URL', '')
  config.notify_url = ENV.fetch('WEBPAY_NOTIFY_URL', '')
  config.currency_id = ENV.fetch('WEBPAY_CURRENCY_ID', 'BYN')
  config.language_id = ENV.fetch('WEBPAY_LANGUAGE_ID', 'russian')
  config.version = ENV.fetch('WEBPAY_VERSION', '2')
  config.test_flag = ENV.fetch('WEBPAY_TEST_FLAG', '1')
  config.payment_page_url = ENV.fetch('WEBPAY_PAYMENT_PAGE_URL', 'https://securesandbox.webpay.by/')
  config.link_base_url = ENV.fetch('WEBPAY_LINK_BASE_URL', ENV.fetch('API_BASE_URL', 'http://localhost:3000'))
end
