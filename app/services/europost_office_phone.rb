# frozen_string_literal: true

# Resolves a display phone for Europost pickup points.
# REST /api/external/stores and legacy Postal.OfficesOut do not expose a dedicated phone field today;
# we read known keys when present and fall back to EUROPOST_PVZ_PHONE (carrier contact center).
class EuropostOfficePhone
  DIRECT_KEYS = %w[
    phone Phone PHONE
    phone_number phoneNumber PhoneNumber
    contact_phone contactPhone ContactPhone
    WarehousePhone warehouse_phone
    tel telephone mobile
  ].freeze

  TEXT_FIELD_KEYS = %w[Note Info1 Info2 Info3].freeze

  PHONE_PATTERN = /
    (?<!\d)
    (?:\+?375|80)\s*[\(\-\s]*
    (?:\(?\d{2}\)?[\s\-]*)?
    \d{3}[\s\-]*
    \d{2}[\s\-]*
    \d{2}
    (?!\d)
  /x.freeze

  DEFAULT_PHONE = "+375295353636"

  def self.for_office(office)
    new(office).resolve
  end

  def initialize(office)
    @office = office.is_a?(Hash) ? office : {}
  end

  def resolve
    direct = extract_direct_key
    return normalize(direct) if direct.present?

    from_text = extract_from_text_fields
    return normalize(from_text) if from_text.present?

    default_phone
  end

  private

  attr_reader :office

  def extract_direct_key
    DIRECT_KEYS.each do |key|
      value = office[key] || office[key.to_sym]
      normalized = normalize(value)
      return normalized if normalized.present?
    end
    nil
  end

  def extract_from_text_fields
    TEXT_FIELD_KEYS.each do |key|
      text = office[key] || office[key.to_sym]
      match = text.to_s.match(PHONE_PATTERN)
      return match[0] if match
    end
    nil
  end

  def normalize(value)
    digits = value.to_s.gsub(/\D/, "")
    return nil if digits.length < 9

    if digits.start_with?("80") && digits.length >= 11
      digits = "375#{digits[2..]}"
    end

    digits = "375#{digits}" if digits.length == 9

    return nil unless digits.start_with?("375") && digits.length >= 11

    "+#{digits}"
  end

  def default_phone
    env = ENV["EUROPOST_PVZ_PHONE"].to_s.strip
    return nil if env.casecmp("none").zero? || env == "-"

    normalize(env).presence || DEFAULT_PHONE
  end
end
