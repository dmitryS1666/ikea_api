class DeliveryTypeNormalizer
  LEGACY_PICKUP = "pickup".freeze

  EUROPOST_PICKUP = "europost_pickup".freeze
  COURIER = "courier".freeze
  IKEYA_DELIVERY = "ikeya_delivery".freeze

  SUPPORTED_TYPES = [
    EUROPOST_PICKUP,
    COURIER,
    IKEYA_DELIVERY
  ].freeze

  def self.normalize(value)
    normalized = value.to_s.strip.downcase

    case normalized
    when LEGACY_PICKUP, EUROPOST_PICKUP
      EUROPOST_PICKUP
    when COURIER
      COURIER
    when IKEYA_DELIVERY
      IKEYA_DELIVERY
    else
      normalized
    end
  end
end
