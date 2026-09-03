# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebpayConfig do
  around do |example|
    keys = %w[
      WEBPAY_TEST_STORE_ID WEBPAY_TEST_SECRET_KEY
      WEBPAY_LIVE_STORE_ID WEBPAY_LIVE_SECRET_KEY
      WEBPAY_STORE_ID WEBPAY_SECRET_KEY
      WEBPAY_LIVE_PAYMENT_PAGE_URL WEBPAY_LIVE_BILLING_API_URL
      WEBPAY_TEST_PAYMENT_PAGE_URL WEBPAY_TEST_BILLING_API_URL
    ]
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  describe ".current" do
    it "uses sandbox defaults in test mode" do
      WebpaySetting.instance.update!(test_mode: true)

      cfg = described_class.current
      expect(cfg.test_flag).to eq("1")
      expect(cfg.payment_page_url).to eq("https://securesandbox.webpay.by/")
      expect(cfg.billing_api_url).to eq("https://sandbox.webpay.by")
      expect(cfg.store_id).to eq("11111111")
      expect(cfg.notify_trusted_ips).to eq([])
    end

    it "uses production URLs and live credentials when test mode is off" do
      ENV["WEBPAY_LIVE_STORE_ID"] = "99999999"
      ENV["WEBPAY_LIVE_SECRET_KEY"] = "live-secret"
      ENV["WEBPAY_NOTIFY_TRUSTED_IPS"] = "178.163.225.84"
      Rails.application.config.x.webpay.notify_trusted_ips = ["178.163.225.84"]
      WebpaySetting.instance.update!(test_mode: false)

      cfg = described_class.current
      expect(cfg.test_flag).to eq("0")
      expect(cfg.payment_page_url).to eq("https://payment.webpay.by/")
      expect(cfg.billing_api_url).to eq("https://billing.webpay.by")
      expect(cfg.store_id).to eq("99999999")
      expect(cfg.secret_key).to eq("live-secret")
      expect(cfg.notify_trusted_ips).to eq(["178.163.225.84"])
    end

    it "falls back to WEBPAY_STORE_ID for live credentials" do
      ENV["WEBPAY_STORE_ID"] = "55555555"
      ENV["WEBPAY_SECRET_KEY"] = "shared-secret"
      WebpaySetting.instance.update!(test_mode: false)

      cfg = described_class.current
      expect(cfg.store_id).to eq("55555555")
      expect(cfg.secret_key).to eq("shared-secret")
    end

    it "does not use live WEBPAY_STORE_ID while in test mode" do
      ENV["WEBPAY_STORE_ID"] = "55555555"
      ENV["WEBPAY_SECRET_KEY"] = "shared-secret"
      WebpaySetting.instance.update!(test_mode: true)

      cfg = described_class.current
      expect(cfg.store_id).to eq("11111111")
      expect(cfg.secret_key).to eq(WebpayConfig::TEST_SECRET_KEY_DEFAULT)
    end
  end
end
