# frozen_string_literal: true

# POST /api/external/postal/payment/calculate — предварительный тариф Европочты.
# API Европочты v1.8.2 не принимает произвольный payload: для доставки до ОПС
# обязательны is_juristic, delivery_type, store_id_start, store_id_finish и weight.
class EuropostPostalPaymentQuote
  TOP_LEVEL_AMOUNT_KEYS = %w[total amount price cost sum Total Amount Price Cost Sum].freeze
  RESPONSE_PRICE_KEYS = %w[
    cash_on_delivery_price completeness_price declared_price fragile_price inventory_price
    oversize_price relabeling_price shipment_price receiver_pays sender_pays
  ].freeze

  def self.call(weight_kg:, pln_rate_with_buffer:, parcels: nil, pickup_point_id: nil)
    if ENV["EUROPOST_API_TOKEN"].to_s.strip.blank?
      return build_result(success: false, reason: "europost_token_missing", postal_total_byn: nil, currency: nil, payload: nil, raw: nil)
    end

    payload = build_request_payload(weight_kg, parcels, pickup_point_id)
    unless payload[:ok]
      return build_result(
        success: false,
        reason: payload[:reason],
        error: payload[:error],
        postal_total_byn: nil,
        currency: nil,
        payload: payload[:payload],
        raw: nil
      )
    end

    raw = EuropostApiService.postal_payment_calculate(data: payload[:payload])
    parsed = extract_amount_and_currency(raw)
    unless parsed[:amount].is_a?(Numeric) && parsed[:amount].to_f.positive?
      return build_result(
        success: false,
        reason: "europost_unrecognized_response",
        postal_total_byn: nil,
        currency: parsed[:currency],
        payload: payload[:payload],
        raw: raw
      )
    end

    byn = convert_to_byn(parsed[:amount].to_f, parsed[:currency].to_s, pln_rate_with_buffer)
    build_result(
      success: true,
      reason: nil,
      postal_total_byn: byn.round(2),
      currency: parsed[:currency].presence || "BYN",
      payload: payload[:payload],
      raw: raw
    )
  rescue EuropostApiService::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.warn("[EUROPOST] postal_payment_calculate #{e.class}: #{e.message}")
    build_result(success: false, reason: "europost_api_error", error: e.message, postal_total_byn: nil, currency: nil, payload: defined?(payload) && payload.is_a?(Hash) ? payload[:payload] : nil, raw: nil)
  rescue StandardError => e
    Rails.logger.warn("[EUROPOST] postal_payment_calculate #{e.class}: #{e.message}")
    build_result(success: false, reason: "europost_api_error", error: e.message, postal_total_byn: nil, currency: nil, payload: defined?(payload) && payload.is_a?(Hash) ? payload[:payload] : nil, raw: nil)
  end

  def self.build_request_payload(weight_kg, _parcels, pickup_point_id)
    start_store_id = integer_env("EUROPOST_STORE_ID_START")
    finish_store_id = integer_value(pickup_point_id) || integer_env("EUROPOST_STORE_ID_FINISH")

    payload = {
      "is_juristic" => boolean_env("EUROPOST_IS_JURISTIC", true),
      "delivery_type" => integer_env("EUROPOST_DELIVERY_TYPE", 1),
      "store_id_start" => start_store_id,
      "store_id_finish" => finish_store_id,
      "weight" => weight_kg.to_f.round(3),
      "shipment_payer" => integer_env("EUROPOST_SHIPMENT_PAYER", 0),
      "cash_on_delivery_payer" => integer_env("EUROPOST_CASH_ON_DELIVERY_PAYER", 1)
    }

    copy_optional_float_env!(payload, "declared_amount", "EUROPOST_DECLARED_AMOUNT")
    copy_optional_float_env!(payload, "payment_amount", "EUROPOST_PAYMENT_AMOUNT")
    copy_optional_bool_env!(payload, "is_completeness_check", "EUROPOST_IS_COMPLETENESS_CHECK")
    copy_optional_bool_env!(payload, "is_fragile", "EUROPOST_IS_FRAGILE")
    copy_optional_bool_env!(payload, "is_inventory", "EUROPOST_IS_INVENTORY")
    copy_optional_bool_env!(payload, "is_oversize", "EUROPOST_IS_OVERSIZE")
    copy_optional_bool_env!(payload, "is_relabeling", "EUROPOST_IS_RELABELING")

    missing = []
    missing << "EUROPOST_STORE_ID_START" if start_store_id.blank?
    missing << "pickup_point_id/EUROPOST_STORE_ID_FINISH" if finish_store_id.blank?
    missing << "weight" unless payload["weight"].positive?

    return { ok: true, payload: payload.compact } if missing.empty?

    {
      ok: false,
      reason: "europost_payload_missing_required_fields",
      error: "Missing required Europost payment fields: #{missing.join(', ')}",
      payload: payload.compact
    }
  end
  private_class_method :build_request_payload

  def self.extract_amount_and_currency(raw)
    return { amount: nil, currency: nil } unless raw.is_a?(Hash)

    sender_pays = coerce_number(raw["sender_pays"] || raw[:sender_pays])
    receiver_pays = coerce_number(raw["receiver_pays"] || raw[:receiver_pays])
    if sender_pays || receiver_pays
      return { amount: sender_pays.to_f + receiver_pays.to_f, currency: raw["currency"] || raw[:currency] || "BYN" }
    end

    shipment_price = coerce_number(raw["shipment_price"] || raw[:shipment_price])
    return { amount: shipment_price, currency: raw["currency"] || raw[:currency] || "BYN" } if shipment_price

    TOP_LEVEL_AMOUNT_KEYS.each do |k|
      v = raw[k] || raw[k.to_sym]
      next if v.nil?

      num = coerce_number(v)
      return { amount: num, currency: raw["currency"] || raw[:currency] || raw["Currency"] } if num
    end

    RESPONSE_PRICE_KEYS.each do |k|
      v = raw[k] || raw[k.to_sym]
      next if v.nil?

      num = coerce_number(v)
      return { amount: num, currency: raw["currency"] || raw[:currency] || "BYN" } if num
    end

    nested = raw["data"] || raw[:data]
    inner = extract_amount_and_currency(nested) if nested.is_a?(Hash)
    return inner if inner && inner[:amount]

    { amount: nil, currency: raw["currency"] || raw[:currency] }
  end
  private_class_method :extract_amount_and_currency

  def self.coerce_number(value)
    case value
    when Numeric
      value.to_f.positive? ? value.to_f : nil
    when String
      s = value.tr(",", ".").strip
      Float(s) if s.match?(/\A\d+(\.\d+)?\z/) && s.to_f.positive?
    else
      nil
    end
  end
  private_class_method :coerce_number

  def self.convert_to_byn(amount, currency, pln_rate_with_buffer)
    c = currency.to_s.strip.upcase
    return amount.round(2) if c.blank? || c == "BYN"

    return (amount * pln_rate_with_buffer).round(2) if c == "PLN"

    amount.round(2)
  end
  private_class_method :convert_to_byn

  def self.integer_env(key, default = nil)
    v = ENV[key].to_s.strip
    return default if v.blank?

    Integer(v)
  rescue ArgumentError
    default
  end
  private_class_method :integer_env

  def self.integer_value(value)
    v = value.to_s.strip
    return nil if v.blank?

    Integer(v)
  rescue ArgumentError
    nil
  end
  private_class_method :integer_value

  def self.boolean_env(key, default = nil)
    v = ENV[key].to_s.strip.downcase
    return default if v.blank?
    return true if %w[1 true yes y да].include?(v)
    return false if %w[0 false no n нет].include?(v)

    default
  end
  private_class_method :boolean_env

  def self.copy_optional_float_env!(payload, payload_key, env_key)
    value = ENV[env_key].to_s.strip
    return if value.blank?

    payload[payload_key] = Float(value.tr(",", "."))
  rescue ArgumentError
    Rails.logger.warn("[EUROPOST] #{env_key} must be a number")
  end
  private_class_method :copy_optional_float_env!

  def self.copy_optional_bool_env!(payload, payload_key, env_key)
    return unless ENV.key?(env_key)

    payload[payload_key] = boolean_env(env_key, false)
  end
  private_class_method :copy_optional_bool_env!

  def self.build_result(success:, reason:, postal_total_byn:, currency:, payload:, raw:, error: nil)
    {
      success: success,
      reason: reason,
      error: error,
      postal_total_byn: postal_total_byn,
      currency: currency,
      payload: payload,
      raw: raw
    }
  end
  private_class_method :build_result
end
