# frozen_string_literal: true

# POST /api/external/postal/payment/calculate — предварительный тариф Европочты.
# Контракт ответа API может отличаться; извлекаем сумму по распространённым ключам.
class EuropostPostalPaymentQuote
  TOP_LEVEL_AMOUNT_KEYS = %w[total amount price cost sum Total Amount Price Cost Sum].freeze

  def self.call(weight_kg:, pln_rate_with_buffer:, parcels: nil, pickup_point_id: nil)
    if ENV["EUROPOST_API_TOKEN"].to_s.strip.blank?
      return build_result(success: false, reason: "europost_token_missing", postal_total_byn: nil, currency: nil, payload: nil, raw: nil)
    end

    payload = build_request_payload(weight_kg, parcels, pickup_point_id)
    raw = EuropostApiService.postal_payment_calculate(data: payload)
    parsed = extract_amount_and_currency(raw)
    unless parsed[:amount].is_a?(Numeric) && parsed[:amount].to_f.positive?
      return build_result(
        success: false,
        reason: "europost_unrecognized_response",
        postal_total_byn: nil,
        currency: parsed[:currency],
        payload: payload,
        raw: raw
      )
    end

    byn = convert_to_byn(parsed[:amount].to_f, parsed[:currency].to_s, pln_rate_with_buffer)
    build_result(
      success: true,
      reason: nil,
      postal_total_byn: byn.round(2),
      currency: parsed[:currency].presence || "BYN",
      payload: payload,
      raw: raw
    )
  rescue EuropostApiService::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.warn("[EUROPOST] postal_payment_calculate #{e.class}: #{e.message}")
    build_result(success: false, reason: "europost_api_error", error: e.message, postal_total_byn: nil, currency: nil, payload: defined?(payload) ? payload : nil, raw: nil)
  rescue StandardError => e
    Rails.logger.warn("[EUROPOST] postal_payment_calculate #{e.class}: #{e.message}")
    build_result(success: false, reason: "europost_api_error", error: e.message, postal_total_byn: nil, currency: nil, payload: defined?(payload) ? payload : nil, raw: nil)
  end

  def self.build_request_payload(weight_kg, parcels, _pickup_point_id)
    h = { "weight" => weight_kg.to_f.round(3) }
    dims = representative_dimensions_cm(parcels)
    h.merge!(dims) if dims.any?
    h
  end
  private_class_method :build_request_payload

  def self.representative_dimensions_cm(parcels)
    return {} unless parcels.is_a?(Array)

    p = parcels.max_by { |x| x[:volume_m3].to_f }
    return {} unless p.is_a?(Hash)

    w = p[:width_cm].to_f
    h = p[:height_cm].to_f
    d = p[:depth_cm].to_f
    return {} if [w, h, d].any?(&:<=)

    sides = [w, h, d].sort.reverse
    { "length" => sides[0], "width" => sides[1], "height" => sides[2] }
  end
  private_class_method :representative_dimensions_cm

  def self.extract_amount_and_currency(raw)
    return { amount: nil, currency: nil } unless raw.is_a?(Hash)

    TOP_LEVEL_AMOUNT_KEYS.each do |k|
      v = raw[k] || raw[k.to_sym]
      next if v.nil?

      num = coerce_number(v)
      return { amount: num, currency: raw["currency"] || raw[:currency] || raw["Currency"] } if num
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
