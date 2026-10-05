# frozen_string_literal: true

require "date"
require "uri"

module PolandTracks
  class Payload
    class Invalid < StandardError; end

    DELIVERY_TYPES = { "europost_pickup" => 1, "courier" => 4, "ikeya_delivery" => 5 }.freeze

    def self.delivery_type(order)
      DELIVERY_TYPES[DeliveryTypeNormalizer.normalize(order.delivery_type)]
    end

    RECIPIENT_REQUIRED = %w[first_name last_name phone birthdate document_country address_country
                            passport_serial passport_number passport_date passport_founder region city street building index].freeze

    def self.snapshot(order)
      new(order).snapshot
    end

    def initialize(order)
      @order = order
    end

    def snapshot
      user = @order.user
      raise Invalid, "recipient: missing user" unless user

      passport_data = user.passport_data || {}
      raise Invalid, "recipient: invalid passport structure" unless passport_data.is_a?(Hash)
      passport = passport_data.stringify_keys
      serial = value(passport, "passport_serial", "series").to_s.gsub(/\s/, "").upcase
      number = value(passport, "passport_number", "number").to_s.gsub(/\s/, "").upcase
      if serial.empty? && (match = number.match(/\A([A-Z]{2})(\d{7})\z/))
        serial, number = match.captures
      elsif serial.empty? && (match = number.match(/\A(\d{4})(\d{6})\z/))
        serial, number = match.captures
      elsif serial.present? && number.start_with?(serial) && number.length > 7
        number = number.delete_prefix(serial)
      end
      document_country = country(value(passport, "document_country"))
      document_country ||= "by" if serial.match?(/\A[A-Z]{2}\z/)
      document_country ||= "ru" if serial.match?(/\A\d{4}\z/)
      phone = (@order.phone.presence || user.phone).to_s.gsub(/\D/, "")
      registration = registration_address(user, passport)

      recipient = {
        "first_name" => user.first_name.presence || passport["first_name"],
        "middle_name" => user.middle_name.presence || passport["middle_name"],
        "last_name" => user.last_name.presence || passport["last_name"],
        "email" => user.email,
        "phone" => phone.present? ? "+#{phone}" : nil,
        "phone_country" => phone.start_with?("375") ? "by" : (phone.start_with?("7") ? "ru" : nil),
        "birthdate" => formatted_date(user.dob.presence || value(passport, "birthdate", "dob", "birth_date", "date_of_birth", "birthday")),
        "document_country" => document_country,
        "address_country" => country(value(passport, "address_country")) || country(user.country_code) || document_country,
        "passport_serial" => serial,
        "passport_number" => number,
        "iin" => value(passport, "iin", "id_number", "personal_number", "identification_number"),
        "passport_date" => formatted_date(value(passport, "passport_date", "issued_date", "issued_at", "issue_date")),
        "passport_founder" => value(passport, "passport_founder", "issued_by"),
        "region" => registration["region"], "city" => registration["city"], "street" => registration["street"],
        "building" => registration["house"], "corpus" => registration["building"],
        "apartment" => registration["apartment"], "index" => registration["postcode"]
      }
      # Send no placeholder/null email. ShopByShop may still reject its omission.
      recipient.delete("email") if recipient["email"].blank?

      payload = {
        "delivery_type" => self.class.delivery_type(@order),
        # ShopByShop contract: total order weight in grams, string, root field.
        "weight" => weight_grams,
        "nomerikea" => @order.public_uid.presence || @order.id.to_s,
        "recipient" => recipient,
        "items" => self.class.item_rows(@order)
      }
      if payload["delivery_type"] == 1
        address = (@order.address_json || {}).deep_stringify_keys
        raw_pvz = address["pickup_point_id"].presence ||
                  address.dig("delivery", "pickup_point", "external_id").presence ||
                  address.dig("delivery", "pickup_point", "id").presence
        payload["pvz"] = raw_pvz.to_s.match?(/\A[1-9]\d*\z/) ? raw_pvz.to_i : nil
      else
        payload["delivery_address"] = delivery_address
      end
      payload
    end

    def self.for_export(export, allow_missing_track: false)
      payload = JSON.parse(export.payload_json.presence || "{}")
      raise Invalid, "payload: invalid snapshot structure" unless payload.is_a?(Hash)
      # Store all delivery fields at payment. Only the provider track arrives later.
      # A reconciled retry already contains the original track and reuses it exactly.
      if [1, 4].include?(payload["delivery_type"]) && payload["europost_track"].blank?
        order = export.order
        payload["europost_track"] = order.resolved_track_number
        if payload["delivery_type"] == 1
          actual_pvz = order.tracking_info&.dig("europost_create", "payload", "store_id_finish")
          if actual_pvz.present?
            raise Invalid, "pvz: invalid provider ID" unless actual_pvz.to_s.match?(/\A[1-9]\d*\z/)
            payload["pvz"] = actual_pvz.to_i
          end
        end
      end
      # Older September snapshots may lack weight; fill from the order before POST.
      payload = with_weight(payload, new(export.order).weight_grams) if payload["weight"].blank?
      # Orders created before PLN/URL snapshotting (or with a lost catalog link)
      # stay blocked forever unless we heal missing item fields from the catalog.
      payload = with_item_snapshots(payload, export.order) if items_need_heal?(payload)
      validate!(payload, allow_missing_track: allow_missing_track)
      payload
    rescue JSON::ParserError
      raise Invalid, "payload: invalid snapshot"
    end

    def self.item_rows(order)
      order.order_items.order(:id).map do |item|
        item.ensure_poland_snapshot!
        {
          "name" => item.name_snapshot,
          "count" => item.quantity,
          # Never send OrderItem#price: that column contains BYN.
          "price" => item.poland_price_pln&.to_f,
          "link" => item.poland_product_url
        }
      end
    end

    def self.items_need_heal?(payload)
      items = payload["items"]
      return true unless items.is_a?(Array) && items.any?

      items.any? do |item|
        !item.is_a?(Hash) ||
          item["name"].blank? ||
          !(item["count"].is_a?(Integer) && item["count"] >= 1) ||
          !(item["price"].is_a?(Numeric) && item["price"].finite? && item["price"] >= 1) ||
          item["link"].blank?
      end
    end

    def self.with_item_snapshots(payload, order)
      healed = item_rows(order)
      items = Array(payload["items"]).map.with_index do |item, index|
        item = item.is_a?(Hash) ? item.dup : {}
        source = healed[index]
        next item unless source

        item["name"] = source["name"] if item["name"].blank?
        item["count"] = source["count"] unless item["count"].is_a?(Integer) && item["count"] >= 1
        unless item["price"].is_a?(Numeric) && item["price"].finite? && item["price"] >= 1
          item["price"] = source["price"]
        end
        item["link"] = source["link"] if item["link"].blank?
        item
      end
      items = healed if items.empty?
      payload.merge("items" => items)
    end

    def self.with_weight(payload, weight)
      rebuilt = {}
      payload.each do |key, value|
        rebuilt[key] = value
        rebuilt["weight"] = weight if key == "delivery_type" && !rebuilt.key?("weight")
      end
      rebuilt["weight"] = weight unless rebuilt.key?("weight")
      rebuilt
    end

    def self.validate!(payload, allow_missing_track: false)
      type = payload["delivery_type"]
      raise Invalid, "delivery_type: expected 1, 4 or 5" unless [1, 4, 5].include?(type)
      unless payload["weight"].is_a?(String) && payload["weight"].match?(/\A[1-9]\d*\z/)
        raise Invalid, "weight: expected positive grams string"
      end
      required = ["nomerikea"]
      required << "europost_track" if [1, 4].include?(type) && !allow_missing_track
      required << "delivery_address" if [4, 5].include?(type)
      missing = required.select { |key| payload[key].blank? }
      if type == 1
        raise Invalid, "pvz: expected positive provider ID" unless payload["pvz"].is_a?(Integer) && payload["pvz"] > 0
        raise Invalid, "delivery_address: unexpected for pickup" if payload.key?("delivery_address")
      else
        raise Invalid, "pvz: unexpected for courier" if payload.key?("pvz")
      end
      if type == 5 && payload.key?("europost_track")
        raise Invalid, "europost_track: unexpected for IKEYA delivery"
      end
      recipient = payload["recipient"].is_a?(Hash) ? payload["recipient"] : {}
      missing += RECIPIENT_REQUIRED.filter_map { |key| "recipient.#{key}" if recipient[key].blank? }
      raise Invalid, "Missing fields: #{missing.join(', ')}" if missing.any?
      %w[document_country address_country phone_country].each do |key|
        raise Invalid, "recipient.#{key}: expected by or ru" unless %w[by ru].include?(recipient[key])
      end
      phone_pattern = recipient["phone_country"] == "by" ? /\A\+375\d{9}\z/ : /\A\+7\d{10}\z/
      raise Invalid, "recipient.phone: invalid format" unless recipient["phone"].match?(phone_pattern)
      if recipient["email"].present? && !recipient["email"].to_s.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        raise Invalid, "recipient.email: invalid format"
      end
      by = recipient["document_country"] == "by"
      serial_pattern = by ? /\A[A-Z]{2}\z/ : /\A\d{4}\z/
      number_pattern = by ? /\A\d{7}\z/ : /\A\d{6}\z/
      raise Invalid, "recipient.passport_serial: invalid format" unless recipient["passport_serial"].to_s.match?(serial_pattern)
      raise Invalid, "recipient.passport_number: invalid format" unless recipient["passport_number"].to_s.match?(number_pattern)
      raise Invalid, "recipient.iin: required for BY" if by && recipient["iin"].blank?
      if !by && recipient["iin"].present? && !recipient["iin"].to_s.match?(/\A\d{12}\z/)
        raise Invalid, "recipient.iin: expected 12 digits for RU"
      end
      %w[birthdate passport_date].each do |key|
        date = recipient[key].to_s
        raise Invalid, "recipient.#{key}: invalid date" unless date.match?(/\A\d{2}\.\d{2}\.\d{4}\z/) && Date.strptime(date, "%d.%m.%Y").strftime("%d.%m.%Y") == date
      rescue Date::Error
        raise Invalid, "recipient.#{key}: invalid date"
      end
      items = payload["items"]
      raise Invalid, "items: empty" unless items.is_a?(Array) && items.any?
      items.each_with_index do |item, index|
        valid = item.is_a?(Hash) && item["name"].present? &&
                item["count"].is_a?(Integer) && item["count"] >= 1 &&
                item["price"].is_a?(Numeric) && item["price"].finite? && item["price"] >= 1
        raise Invalid, "items[#{index}]: name, count or PLN snapshot missing/invalid" unless valid
        uri = URI.parse(item["link"].to_s)
        raise Invalid, "items[#{index}].link: invalid URL" unless %w[https http].include?(uri.scheme) && uri.host.present?
      rescue URI::InvalidURIError
        raise Invalid, "items[#{index}].link: invalid URL"
      end
      true
    end

    def weight_grams
      kg = @order.weight.presence
      if kg.blank?
        address = (@order.address_json || {}).deep_stringify_keys
        kg = address["weight_kg"].presence || address.dig("delivery", "weight_kg")
      end
      if kg.blank? && @order.respond_to?(:pricing_snapshot) && @order.pricing_snapshot.is_a?(Hash)
        snap = @order.pricing_snapshot.deep_stringify_keys
        kg = snap["total_weight_kg"].presence || snap.dig("totals", "total_weight_kg")
      end
      grams = (kg.to_f * 1000).round
      raise Invalid, "weight: missing or not positive" unless grams >= 1

      grams.to_s
    end

    private

    def registration_address(user, passport)
      fields = %w[region city street house building apartment postcode]
      profile = fields.to_h { |key| [key, user.public_send(key)] }
      # Legacy checkout stored registration inside the encrypted passport JSON.
      # Select a whole source: never splice two different addresses together.
      # A partial profile remains invalid until corrected explicitly.
      return profile if profile.values.any?(&:present?)

      passport.slice(*fields)
    end

    def delivery_address
      root = (@order.address_json || {}).deep_stringify_keys
      address = root.dig("delivery", "address").presence || root
      return nil unless address.is_a?(Hash)
      full = value(address, "address_full", "full_address")
      return full if full.present?

      city = value(address, "city", "address_city")
      street = value(address, "street", "address_street")
      house = value(address, "house", "house_number", "address_house_number")
      return nil if [city, street, house].any?(&:blank?)
      corpus = value(address, "building", "corpus")
      apartment = value(address, "apartment", "flat", "flat_number")
      [city, street, "д. #{house}", corpus.present? ? "корп. #{corpus}" : nil,
       apartment.present? ? "кв. #{apartment}" : nil].compact.join(", ")
    end

    def value(hash, *keys)
      keys.filter_map { |key| hash[key].presence }.first
    end

    def country(value)
      raw = value.to_s.strip.downcase.presence
      { "rb" => "by", "рб" => "by", "рф" => "ru", "рк" => "kz" }.fetch(raw, raw)
    end

    def formatted_date(value)
      return nil if value.blank?
      return value.strftime("%d.%m.%Y") if value.respond_to?(:strftime)

      raw = value.to_s.strip
      format = raw.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? "%Y-%m-%d" : "%d.%m.%Y"
      parsed = Date.strptime(raw, format)
      parsed.strftime(format) == raw ? parsed.strftime("%d.%m.%Y") : nil
    rescue Date::Error
      nil
    end
  end
end
