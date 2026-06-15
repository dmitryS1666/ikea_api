# Человекочитаемый адрес доставки из order.address_json (legacy + delivery snapshot).
class OrderAddressFormatter
  class << self
    def display(order)
      aj = order.address_json
      return if aj.blank?

      format_courier_hash(courier_address_hash(aj)) ||
        format_pickup_point(aj.dig("delivery", "pickup_point"))
    end

    def elevator_type(order)
      raw = courier_address_hash(order.address_json)
      return if raw.blank?

      raw["elevator_type"].presence || (raw["has_elevator"] ? "passenger" : nil)
    end

    def elevator_type_label(order)
      label_for_elevator_type(elevator_type(order))
    end

    def intercom(order)
      courier_address_hash(order.address_json)&.dig("intercom").presence
    end

    private

    def courier_address_hash(aj)
      return if aj.blank?

      aj = aj.stringify_keys
      delivery_address = aj.dig("delivery", "address")
      return delivery_address.stringify_keys if delivery_address.present?

      legacy_courier_slice(aj)
    end

    def legacy_courier_slice(aj)
      return unless aj["city"].present? || aj["street"].present? || aj["house"].present?

      aj.slice("city", "street", "house", "building", "apartment", "entrance", "floor", "comment", "elevator_type", "has_elevator", "intercom")
    end

    def format_courier_hash(raw)
      return if raw.blank?

      h = raw.respond_to?(:stringify_keys) ? raw.stringify_keys : raw.to_h.stringify_keys
      chunks = [
        h["city"],
        h["street"],
        h["house"].present? ? "д. #{h['house']}" : nil,
        h["building"].present? ? "корп. #{h['building']}" : nil,
        h["apartment"].present? ? "кв. #{h['apartment']}" : nil,
        h["entrance"].present? ? "подъезд #{h['entrance']}" : nil,
        h["floor"].present? ? "этаж #{h['floor']}" : nil,
        label_for_elevator_type(h["elevator_type"].presence || (h["has_elevator"] ? "passenger" : nil)),
        h["intercom"].present? ? "домофон #{h['intercom']}" : nil,
        h["comment"].present? ? h["comment"] : nil
      ].compact

      chunks.join(", ").presence
    end

    def label_for_elevator_type(type)
      UserDeliveryAddress::ELEVATOR_TYPE_LABELS[type]
    end

    def format_pickup_point(raw)
      return if raw.blank?

      h = raw.respond_to?(:stringify_keys) ? raw.stringify_keys : raw.to_h.stringify_keys
      label = h["name"].presence || "ПВЗ"
      location = [h["city"], h["address"]].map(&:presence).compact.join(", ")
      [label, location.presence].compact.join(" — ").presence
    end
  end
end
