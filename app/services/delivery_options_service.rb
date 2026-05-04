class DeliveryOptionsService
  EUROPOST_PICKUP = DeliveryTypeNormalizer::EUROPOST_PICKUP
  COURIER = DeliveryTypeNormalizer::COURIER
  IKEYA_DELIVERY = DeliveryTypeNormalizer::IKEYA_DELIVERY

  def self.call(cart)
    parcel_result = Delivery::ParcelPackingService.call(cart)
    europost_eligibility = europost_cart_eligibility(parcel_result: parcel_result)

    {
      cart_vgh: {
        weight_kg: parcel_result[:total_weight_kg],
        volume_m3: parcel_result[:total_volume_m3],
        max_dimension_cm: parcel_result[:max_dimension_cm],
        eligible_for_europost: europost_eligibility[:eligible],
        ineligible_reason: europost_eligibility[:reason]
      },
      parcel_summary: {
        parcels_count: parcel_result[:parcels].size,
        total_weight_kg: parcel_result[:total_weight_kg],
        total_volume_m3: parcel_result[:total_volume_m3],
        max_dimension_cm: parcel_result[:max_dimension_cm],
        eligible_for_europost: europost_eligibility[:eligible],
        ineligible_reason: europost_eligibility[:reason]
      },
      parcels: parcel_result[:parcels],
      methods: delivery_methods(europost_eligibility)
    }
  end

  def self.europost_cart_eligibility(parcel_result:)
    return { eligible: false, reason: normalize_ineligible_reason(parcel_result[:ineligible_reason]) } unless parcel_result[:eligible_for_europost]

    offices = europost_offices
    return { eligible: false, reason: "europost_pickup_points_unavailable" } if offices.empty?

    eligible = offices.any? { |office| europost_office_supports_parcels?(office: office, parcels: parcel_result[:parcels]) }

    eligible ? { eligible: true, reason: nil } : { eligible: false, reason: "europost_pickup_points_constraints_failed" }
  end

  def self.normalize_ineligible_reason(reason)
    return "missing_vgh_data" if reason.to_s.start_with?("missing_")

    reason || "missing_vgh_data"
  end

  def self.europost_office_supports_parcels?(office:, parcels:)
    weight_limit = europost_office_weight_limit_kg(office)
    return true if weight_limit.blank?

    Array(parcels).all? { |parcel| parcel[:weight_kg].to_f <= weight_limit.to_f }
  end

  def self.europost_office_weight_limit_kg(office)
    return nil unless office.is_a?(Hash)

    value = office["WarehouseWeightLimit"] || office[:WarehouseWeightLimit] || office["max_weight_kg"] || office[:max_weight_kg]
    value.to_f.positive? ? value.to_f : nil
  end

  def self.europost_offices
    EuropostApiService.offices_out
  rescue StandardError => e
    Rails.logger.error("[EUROPOST] offices availability failed #{e.class}: #{e.message}")
    []
  end

  def self.delivery_methods(europost_eligibility)
    if europost_eligibility[:eligible]
      [
        { code: EUROPOST_PICKUP, available: true, reason: nil },
        { code: COURIER, available: true, reason: nil },
        { code: IKEYA_DELIVERY, available: false, reason: "available_only_when_europost_vgh_failed" }
      ]
    else
      reason = europost_eligibility[:reason]
      [
        { code: EUROPOST_PICKUP, available: false, reason: reason },
        { code: COURIER, available: false, reason: reason },
        { code: IKEYA_DELIVERY, available: true, reason: nil }
      ]
    end
  end

end
