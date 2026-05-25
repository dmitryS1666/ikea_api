# Человекочитаемый адрес доставки из order.address_json (legacy + delivery snapshot).
class OrderAddressFormatter
  class << self
    def display(order)
      aj = order.address_json
      return if aj.blank?

      format_courier_hash(aj.dig("delivery", "address")) ||
        format_courier_hash(legacy_courier_slice(aj)) ||
        format_pickup_point(aj.dig("delivery", "pickup_point"))
    end

    private

    def legacy_courier_slice(aj)
      return unless aj["city"].present? || aj["street"].present? || aj["house"].present?

      aj.slice("city", "street", "house", "building", "apartment", "entrance", "floor", "comment")
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
        h["comment"].present? ? h["comment"] : nil
      ].compact

      chunks.join(", ").presence
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
