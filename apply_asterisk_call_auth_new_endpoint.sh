#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f "app/services/asterisk_call_auth_service.rb" ]]; then
  echo "Run this script from Rails project root" >&2
  exit 1
fi

cat > app/services/asterisk_call_auth_service.rb <<'RUBY'
# frozen_string_literal: true

class AsteriskCallAuthService
  include HTTParty

  DEFAULT_ENDPOINT_URL = "https://box.asterisk.by/call/auth"
  DEFAULT_FROM_NUMBERS = %w[
    +375255361737
    +375255361738
    +375255361739
    +375255361740
    +375255361741
    +375255361742
    +375255361743
    +375255361744
    +375255361745
    +375255361746
  ].freeze

  SUCCESS_STATUSES = %w[accepted ok success].freeze

  class << self
    def get_caller_info
      number = available_numbers.sample

      {
        number: number,
        code: number.to_s.last(4)
      }
    end

    def initiate_call(to_phone:, from_number: nil)
      to_phone = normalize_phone(to_phone)
      from_number = normalize_phone(from_number.presence || get_caller_info[:number])

      return { success: false, error: "Неверный номер получателя" } if to_phone.blank?
      return { success: false, error: "Не настроен номер исходящего звонка" } if from_number.blank?
      return { success: false, error: "Не задан ASTERISK_CALL_AUTH_TOKEN" } if auth_token.blank?

      body = {
        from: from_number,
        to: to_phone
      }

      Rails.logger.info(
        "[ASTERISK API CALL] URL=#{endpoint_url} from=#{mask_phone(from_number)} to=#{mask_phone(to_phone)}"
      )

      response = post(
        endpoint_url,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{auth_token}"
        },
        body: body.to_json,
        timeout: request_timeout
      )

      parsed = parse_response(response)

      Rails.logger.info(
        "[ASTERISK API RESPONSE] status=#{response.code} body=#{parsed.inspect}"
      )

      if success_response?(response, parsed)
        { success: true, from: from_number, to: to_phone, response: parsed }
      else
        { success: false, error: error_message(response, parsed), response: parsed }
      end
    rescue StandardError => e
      Rails.logger.error("[ASTERISK API EXCEPTION] #{e.class}: #{e.message}")
      { success: false, error: e.message }
    end

    def available_numbers
      numbers = ENV.fetch("ASTERISK_CALL_AUTH_FROM_NUMBERS", "").split(/[\s,;]+/).filter_map do |value|
        normalize_phone(value)
      end

      numbers.presence || DEFAULT_FROM_NUMBERS
    end

    def endpoint_url
      ENV.fetch("ASTERISK_CALL_AUTH_URL", DEFAULT_ENDPOINT_URL)
    end

    def auth_token
      ENV["ASTERISK_CALL_AUTH_TOKEN"].presence ||
        Rails.application.credentials.dig(:asterisk, :call_auth_token).presence
    end

    def request_timeout
      ENV.fetch("ASTERISK_CALL_AUTH_TIMEOUT", "10").to_i.clamp(1, 30)
    end

    def normalize_phone(value)
      digits = value.to_s.gsub(/\D/, "")
      return nil if digits.blank?

      "+#{digits}"
    end

    private

    def parse_response(response)
      parsed = response.parsed_response
      parsed.is_a?(Hash) ? parsed : { "body" => response.body.to_s }
    rescue StandardError
      { "body" => response.body.to_s }
    end

    def success_response?(response, parsed)
      return false unless response.success?

      status = parsed["status"].to_s.downcase
      result = parsed["result"].to_s.downcase
      success = parsed["success"]

      status.blank? || SUCCESS_STATUSES.include?(status) || SUCCESS_STATUSES.include?(result) || success == true
    end

    def error_message(response, parsed)
      parsed["error"].presence ||
        parsed["message"].presence ||
        parsed["status"].presence ||
        parsed["body"].presence ||
        "HTTP Error #{response.code}"
    end

    def mask_phone(phone)
      value = phone.to_s
      return value if value.length <= 7

      "#{value[0, 4]}***#{value[-4, 4]}"
    end
  end
end
RUBY

python3 - <<'PY'
from pathlib import Path
p = Path('app/admin/phone_auth_setting_admin.rb')
text = p.read_text()
old = '"Если опция выключена, звонок в ASTERISK не выполняется, а код подтверждения всегда статичный: #{PhoneAuthSetting::STATIC_TEST_CODE}."'
new = '"Если опция выключена, звонок в ASTERISK не выполняется, а код подтверждения всегда статичный: #{PhoneAuthSetting::STATIC_TEST_CODE}. Для боевого режима должны быть заданы ENV ASTERISK_CALL_AUTH_TOKEN и, при необходимости, ASTERISK_CALL_AUTH_URL / ASTERISK_CALL_AUTH_FROM_NUMBERS."'
if old in text:
    text = text.replace(old, new)
p.write_text(text)
PY

cat > db/migrate/20260612110000_enable_asterisk_call_auth_setting.rb <<'RUBY'
# frozen_string_literal: true

class EnableAsteriskCallAuthSetting < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:phone_auth_settings)

    if select_value("SELECT COUNT(*) FROM phone_auth_settings").to_i.zero?
      execute <<~SQL.squish
        INSERT INTO phone_auth_settings (asterisk_enabled, created_at, updated_at)
        VALUES (TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    else
      execute <<~SQL.squish
        UPDATE phone_auth_settings
        SET asterisk_enabled = TRUE,
            updated_at = CURRENT_TIMESTAMP
      SQL
    end
  end

  def down
    return unless table_exists?(:phone_auth_settings)

    execute <<~SQL.squish
      UPDATE phone_auth_settings
      SET asterisk_enabled = FALSE,
          updated_at = CURRENT_TIMESTAMP
    SQL
  end
end
RUBY

mkdir -p spec/services
cat > spec/services/asterisk_call_auth_service_spec.rb <<'RUBY'
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AsteriskCallAuthService do
  around do |example|
    old_url = ENV["ASTERISK_CALL_AUTH_URL"]
    old_token = ENV["ASTERISK_CALL_AUTH_TOKEN"]
    old_from_numbers = ENV["ASTERISK_CALL_AUTH_FROM_NUMBERS"]
    old_timeout = ENV["ASTERISK_CALL_AUTH_TIMEOUT"]

    ENV.delete("ASTERISK_CALL_AUTH_URL")
    ENV.delete("ASTERISK_CALL_AUTH_TOKEN")
    ENV.delete("ASTERISK_CALL_AUTH_FROM_NUMBERS")
    ENV.delete("ASTERISK_CALL_AUTH_TIMEOUT")

    example.run
  ensure
    restore_env("ASTERISK_CALL_AUTH_URL", old_url)
    restore_env("ASTERISK_CALL_AUTH_TOKEN", old_token)
    restore_env("ASTERISK_CALL_AUTH_FROM_NUMBERS", old_from_numbers)
    restore_env("ASTERISK_CALL_AUTH_TIMEOUT", old_timeout)
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  describe ".available_numbers" do
    it "uses the new Asterisk caller pool by default" do
      expect(described_class.available_numbers).to eq(
        %w[
          +375255361737
          +375255361738
          +375255361739
          +375255361740
          +375255361741
          +375255361742
          +375255361743
          +375255361744
          +375255361745
          +375255361746
        ]
      )
    end

    it "allows overriding caller numbers from ENV" do
      ENV["ASTERISK_CALL_AUTH_FROM_NUMBERS"] = "+375291111111, +375292222222"

      expect(described_class.available_numbers).to eq(%w[+375291111111 +375292222222])
    end
  end

  describe ".get_caller_info" do
    it "returns a caller number and last four digits as verification code" do
      allow(described_class).to receive(:available_numbers).and_return(["+375255361737"])

      expect(described_class.get_caller_info).to eq(number: "+375255361737", code: "1737")
    end
  end

  describe ".initiate_call" do
    it "posts to the new Asterisk endpoint with bearer auth and from/to numbers" do
      ENV["ASTERISK_CALL_AUTH_TOKEN"] = "test-token"

      request = stub_request(:post, "https://box.asterisk.by/call/auth")
        .with(
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer test-token"
          },
          body: {
            from: "+375255361737",
            to: "+375293363388"
          }.to_json
        )
        .to_return(
          status: 200,
          body: { status: "accepted" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = described_class.initiate_call(
        to_phone: "+375293363388",
        from_number: "+375255361737"
      )

      expect(result).to include(success: true, from: "+375255361737", to: "+375293363388")
      expect(request).to have_been_requested
    end

    it "returns a clear error when token is not configured" do
      result = described_class.initiate_call(
        to_phone: "+375293363388",
        from_number: "+375255361737"
      )

      expect(result).to eq(success: false, error: "Не задан ASTERISK_CALL_AUTH_TOKEN")
    end

    it "normalizes user phone to E.164-like format" do
      ENV["ASTERISK_CALL_AUTH_TOKEN"] = "test-token"

      request = stub_request(:post, "https://box.asterisk.by/call/auth")
        .with(body: { from: "+375255361737", to: "+375293363388" }.to_json)
        .to_return(
          status: 200,
          body: { status: "accepted" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      described_class.initiate_call(
        to_phone: "375 (29) 336-33-88",
        from_number: "375255361737"
      )

      expect(request).to have_been_requested
    end
  end
end
RUBY

ruby -c app/services/asterisk_call_auth_service.rb
ruby -c app/admin/phone_auth_setting_admin.rb
ruby -c db/migrate/20260612110000_enable_asterisk_call_auth_setting.rb
ruby -c spec/services/asterisk_call_auth_service_spec.rb

echo "Done. Now run: bundle exec rails db:migrate && bundle exec rspec spec/services/asterisk_call_auth_service_spec.rb"
