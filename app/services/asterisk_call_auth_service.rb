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
