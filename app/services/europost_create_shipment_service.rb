# frozen_string_literal: true

class EuropostCreateShipmentService
  Result = Struct.new(:success?, :status, :order, :track_number, :payload, :raw_response, :error, keyword_init: true)

  SUPPORTED_DELIVERY_TYPES = [
    DeliveryTypeNormalizer::EUROPOST_PICKUP,
    DeliveryTypeNormalizer::COURIER
  ].freeze

  class Error < StandardError; end
  class PermanentError < Error; end
  class TransientError < Error; end

  def self.call(order)
    new(order).call
  end

  def initialize(order)
    @order = order
  end

  def call
    order.reload
    return skipped(:missing_order, "Order is missing") unless order
    return skipped(:unsupported_delivery_type, "Delivery type does not require Europost shipment") unless supported_delivery_type?

    order.with_lock do
      order.reload
      return success(:already_created, track_number: order.track_number) if order.track_number.present?
      raise PermanentError, "Order #{order.id} is not paid" unless order.paid?
    end

    payload = build_payload
    raw = EuropostApiService.postal_create(data: payload)
    track_number = raw["number"].to_s.strip
    raise TransientError, "Europost create response does not contain number: #{raw.inspect}" if track_number.blank?

    order.with_lock do
      order.reload
      return success(:already_created, track_number: order.track_number, payload: payload, raw_response: raw) if order.track_number.present?

      order.update!(
        track_number: track_number,
        tracking_info: tracking_info_with_success(payload: payload, raw_response: raw, track_number: track_number)
      )
    end

    CrmSyncJob.perform_later('Order', order.id)
    success(:created, track_number: track_number, payload: payload, raw_response: raw)
  rescue PermanentError => e
    record_error(e, permanent: true, payload: defined?(payload) ? payload : nil)
    Result.new(success?: false, status: :permanent_error, order: order, error: e.message, payload: defined?(payload) ? payload : nil)
  rescue EuropostApiService::UnauthorizedError, EuropostApiService::ValidationError => e
    record_error(e, permanent: true, payload: defined?(payload) ? payload : nil)
    Result.new(success?: false, status: :permanent_error, order: order, error: e.message, payload: defined?(payload) ? payload : nil)
  rescue EuropostApiService::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, TransientError => e
    record_error(e, permanent: false, payload: defined?(payload) ? payload : nil)
    raise
  end

  private

  attr_reader :order

  def supported_delivery_type?
    SUPPORTED_DELIVERY_TYPES.include?(normalized_delivery_type)
  end

  def normalized_delivery_type
    DeliveryTypeNormalizer.normalize(order.delivery_type)
  end

  def skipped(status, message)
    Result.new(success?: false, status: status, order: order, error: message)
  end

  def success(status, track_number:, payload: nil, raw_response: nil)
    Result.new(
      success?: true,
      status: status,
      order: order,
      track_number: track_number,
      payload: payload,
      raw_response: raw_response
    )
  end

  def build_payload
    parcel_result = Delivery::ParcelPackingService.call(CartPricingService.order_as_cart(order))
    unless parcel_result[:eligible_for_europost]
      raise PermanentError, "Order #{order.id} is not eligible for Europost: #{parcel_result[:ineligible_reason]}"
    end

    parcels = Array(parcel_result[:parcels])
    dims = shipment_dimensions_from_parcels(parcels)
    receiver = receiver_fields
    payload = {
      "delivery_type" => europost_delivery_type,
      "weight" => parcel_result[:total_weight_kg].to_f.round(3),
      "is_auto_delivery" => boolean_env("EUROPOST_IS_AUTO_DELIVERY", false),
      "store_id_start" => required_integer_env!("EUROPOST_STORE_ID_START"),
      "receiver_phone_number" => normalized_phone,
      "receiver_email" => order.user&.email,
      "receiver_name" => receiver[:name],
      "receiver_surname" => receiver[:surname],
      "receiver_patronymic_name" => receiver[:patronymic_name],
      "info_sender" => info_sender(parcels: parcels, parcel_result: parcel_result),
      "external_id" => external_id,
      "height" => dims[:height],
      "width" => dims[:width],
      "length" => dims[:length],
      "packing_payer" => integer_env("EUROPOST_PACKING_PAYER", 0),
      "shipment_payer" => integer_env("EUROPOST_SHIPMENT_PAYER", 0),
      "cash_on_delivery_payer" => integer_env("EUROPOST_CASH_ON_DELIVERY_PAYER", 1),
      "contractor_unn" => required_integer_env!("EUROPOST_CONTRACTOR_UNN")
    }

    payload["declared_amount"] = order.total_amount.to_f.round(2) if order.total_amount.to_f.positive?
    copy_optional_float_env!(payload, "payment_amount", "EUROPOST_PAYMENT_AMOUNT")
    copy_optional_bool_env!(payload, "is_fragile", "EUROPOST_IS_FRAGILE")
    copy_optional_bool_env!(payload, "is_relabeling", "EUROPOST_IS_RELABELING")
    copy_optional_bool_env!(payload, "is_oversize", "EUROPOST_IS_OVERSIZE")
    copy_optional_bool_env!(payload, "is_completeness_check", "EUROPOST_IS_COMPLETENESS_CHECK")
    copy_optional_bool_env!(payload, "is_inventory", "EUROPOST_IS_INVENTORY")
    copy_optional_datetime_env!(payload, "auto_delivery_time_from", "EUROPOST_AUTO_DELIVERY_TIME_FROM")
    copy_optional_datetime_env!(payload, "auto_delivery_time_to", "EUROPOST_AUTO_DELIVERY_TIME_TO")

    if normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
      payload["store_id_finish"] = pickup_store_id!
    else
      merge_courier_address_fields!(payload)
    end

    missing_required = payload.slice(
      "weight", "store_id_start", "receiver_phone_number", "receiver_name", "receiver_surname", "contractor_unn"
    ).select { |_key, value| value.blank? || value.to_f <= 0 && value.is_a?(Numeric) }
    raise PermanentError, "Missing Europost shipment fields: #{missing_required.keys.join(', ')}" if missing_required.any?

    payload.compact
  end

  def europost_delivery_type
    if normalized_delivery_type == DeliveryTypeNormalizer::COURIER
      integer_env("EUROPOST_COURIER_DELIVERY_TYPE", 2)
    else
      integer_env("EUROPOST_DELIVERY_TYPE", 1)
    end
  end

  def shipment_dimensions_from_parcels(parcels)
    sides = Array(parcels).filter_map do |parcel|
      values = [parcel[:width_cm], parcel[:height_cm], parcel[:depth_cm]].map(&:to_f).select(&:positive?)
      values.size == 3 ? values.sort.reverse : nil
    end

    return {} if sides.blank?

    {
      "length".to_sym => sides.map { |row| row[0] }.max.to_f.round(2),
      "width".to_sym => sides.map { |row| row[1] }.max.to_f.round(2),
      "height".to_sym => sides.map { |row| row[2] }.max.to_f.round(2)
    }
  end

  def receiver_fields
    user = order.user
    surname = user&.last_name.to_s.strip.presence
    name = user&.first_name.to_s.strip.presence
    patronymic_name = user&.middle_name.to_s.strip.presence

    if surname.blank? || name.blank?
      parts = order.full_name.to_s.split(/\s+/).reject(&:blank?)
      surname ||= parts[0]
      name ||= parts[1] || parts[0] || "Покупатель"
      patronymic_name ||= parts[2]
    end

    {
      surname: surname.presence || "Покупатель",
      name: name.presence || "Покупатель",
      patronymic_name: patronymic_name
    }
  end

  def normalized_phone
    raw = order.phone.presence || order.user&.phone
    raw.to_s.gsub(/\D+/, "").presence
  end

  def external_id
    order.payment_order_number.presence || order.public_uid.presence || "order-#{order.id}"
  end

  def pickup_store_id!
    value =
      address_json["pickup_point_id"] ||
      address_json.dig("delivery", "pickup_point", "external_id") ||
      address_json.dig("delivery", "pickup_point", "id") ||
      ENV["EUROPOST_STORE_ID_FINISH"]

    integer_value(value) || raise(PermanentError, "Missing pickup point store_id_finish for order #{order.id}")
  end

  def merge_courier_address_fields!(payload)
    address = courier_address
    payload["address_city"] = pick(address, "address_city", "city")
    payload["address_street"] = pick(address, "address_street", "street")
    payload["address_house_number"] = pick(address, "address_house_number", "house", "house_number")
    payload["flat_number"] = pick(address, "flat_number", "apartment", "flat")
    payload["latitude"] = pick(address, "latitude", "lat")
    payload["longitude"] = pick(address, "longitude", "lng", "lon")
    payload["address_full"] = pick(address, "address_full", "full_address") || build_address_full(payload)

    if payload["address_full"].blank? || payload["address_city"].blank? || payload["address_street"].blank? || payload["address_house_number"].blank?
      raise PermanentError, "Missing courier address fields for Europost shipment"
    end
  end

  def courier_address
    delivery_address = address_json.dig("delivery", "address")
    return delivery_address.stringify_keys if delivery_address.respond_to?(:stringify_keys)

    address_json
  end

  def address_json
    order.address_json.is_a?(Hash) ? order.address_json.stringify_keys : {}
  end

  def pick(hash, *keys)
    keys.each do |key|
      value = hash[key] || hash[key.to_sym]
      return value if value.present?
    end
    nil
  end

  def build_address_full(payload)
    city = payload["address_city"].to_s.strip
    street = payload["address_street"].to_s.strip
    house = payload["address_house_number"].to_s.strip
    flat = payload["flat_number"].to_s.strip
    [city, street, house.present? ? "д. #{house}" : nil, flat.present? ? "кв. #{flat}" : nil].compact_blank.join(", ").presence
  end

  def info_sender(parcels:, parcel_result:)
    "IKEYA order #{external_id}; packages=#{parcels.size}; weight=#{parcel_result[:total_weight_kg]}kg; max_side=#{parcel_result[:max_dimension_cm]}cm"
  end

  def tracking_info_with_success(payload:, raw_response:, track_number:)
    tracking_info_base.merge(
      "europost_create" => {
        "status" => "created",
        "track_number" => track_number,
        "created_at" => Time.current.iso8601,
        "payload" => sanitized_payload(payload),
        "response" => raw_response
      }
    )
  end

  def record_error(error, permanent:, payload: nil)
    return unless order&.persisted?

    order.update_columns(
      tracking_info: tracking_info_base.merge(
        "europost_create" => {
          "status" => permanent ? "permanent_error" : "transient_error",
          "error" => error.message,
          "error_class" => error.class.name,
          "failed_at" => Time.current.iso8601,
          "payload" => payload.present? ? sanitized_payload(payload) : nil
        }.compact
      ),
      updated_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("[EUROPOST] failed to persist shipment error for order=#{order&.id}: #{e.class}: #{e.message}")
  end

  def tracking_info_base
    order.tracking_info.is_a?(Hash) ? order.tracking_info.deep_dup : {}
  end

  def sanitized_payload(payload)
    payload.except(
      "receiver_phone_number",
      "receiver_email",
      "receiver_name",
      "receiver_surname",
      "receiver_patronymic_name",
      "address_full",
      "address_city",
      "address_street",
      "address_house_number",
      "flat_number",
      "latitude",
      "longitude"
    )
  end

  def required_integer_env!(key)
    integer_env(key) || raise(PermanentError, "#{key} is required for Europost shipment creation")
  end

  def integer_env(key, default = nil)
    value = ENV[key].to_s.strip
    return default if value.blank?

    Integer(value)
  rescue ArgumentError
    default
  end

  def integer_value(value)
    value = value.to_s.strip
    return nil if value.blank?

    Integer(value)
  rescue ArgumentError
    nil
  end

  def boolean_env(key, default = nil)
    value = ENV[key].to_s.strip.downcase
    return default if value.blank?
    return true if %w[1 true yes y да].include?(value)
    return false if %w[0 false no n нет].include?(value)

    default
  end

  def copy_optional_float_env!(payload, payload_key, env_key)
    value = ENV[env_key].to_s.strip
    return if value.blank?

    payload[payload_key] = Float(value.tr(",", "."))
  rescue ArgumentError
    Rails.logger.warn("[EUROPOST] #{env_key} must be a number")
  end

  def copy_optional_bool_env!(payload, payload_key, env_key)
    return unless ENV.key?(env_key)

    payload[payload_key] = boolean_env(env_key, false)
  end

  def copy_optional_datetime_env!(payload, payload_key, env_key)
    value = ENV[env_key].to_s.strip
    payload[payload_key] = value if value.present?
  end
end
