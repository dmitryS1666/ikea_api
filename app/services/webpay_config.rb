# frozen_string_literal: true

# Resolves WebPay gateway settings for the current admin-selected mode.
# Shared fields (return/notify URLs, store name, billing login) come from
# Rails.application.config.x.webpay / ENV. Mode-specific fields (test flag,
# payment page, billing API host, store id, secret) switch with WebpaySetting.
class WebpayConfig
  TEST_PAYMENT_PAGE_URL = "https://securesandbox.webpay.by/"
  LIVE_PAYMENT_PAGE_URL = "https://payment.webpay.by/"
  TEST_BILLING_API_URL = "https://sandbox.webpay.by"
  LIVE_BILLING_API_URL = "https://billing.webpay.by"
  TEST_STORE_ID_DEFAULT = "11111111"
  TEST_SECRET_KEY_DEFAULT = "xxxaL8v9AjMPTB7w4bmXDaEcbjMCNqyw"

  class << self
    def current
      base = Rails.application.config.x.webpay
      ActiveSupport::InheritableOptions.new(base.to_h.merge(mode_overrides))
    end

    def test_mode?
      return env_test_mode? unless settings_table_ready?

      WebpaySetting.test_mode?
    end

    private

    def mode_overrides
      if test_mode?
        {
          test_flag: "1",
          payment_page_url: ENV.fetch("WEBPAY_TEST_PAYMENT_PAGE_URL", TEST_PAYMENT_PAGE_URL),
          billing_api_url: ENV.fetch("WEBPAY_TEST_BILLING_API_URL", TEST_BILLING_API_URL),
          store_id: test_store_id,
          secret_key: test_secret_key,
          # Sandbox notify IPs are not fixed; skip IP allowlist in test mode.
          notify_trusted_ips: []
        }
      else
        {
          test_flag: "0",
          payment_page_url: ENV["WEBPAY_LIVE_PAYMENT_PAGE_URL"].presence || LIVE_PAYMENT_PAGE_URL,
          billing_api_url: ENV["WEBPAY_LIVE_BILLING_API_URL"].presence || LIVE_BILLING_API_URL,
          store_id: live_store_id,
          secret_key: live_secret_key,
          notify_trusted_ips: Rails.application.config.x.webpay.notify_trusted_ips
        }
      end
    end

    def test_store_id
      ENV["WEBPAY_TEST_STORE_ID"].presence || TEST_STORE_ID_DEFAULT
    end

    def test_secret_key
      ENV["WEBPAY_TEST_SECRET_KEY"].presence || TEST_SECRET_KEY_DEFAULT
    end

    def live_store_id
      ENV["WEBPAY_LIVE_STORE_ID"].presence ||
        ENV["WEBPAY_STORE_ID"].presence ||
        Rails.application.config.x.webpay.store_id
    end

    def live_secret_key
      ENV["WEBPAY_LIVE_SECRET_KEY"].presence ||
        ENV["WEBPAY_SECRET_KEY"].presence ||
        Rails.application.config.x.webpay.secret_key
    end

    def env_test_mode?
      ENV.fetch("WEBPAY_TEST_FLAG", "1") != "0"
    end

    def settings_table_ready?
      ActiveRecord::Base.connection.data_source_exists?("webpay_settings")
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
      false
    end
  end
end
