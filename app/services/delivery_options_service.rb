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

  def self.pickup_point_eligibility(pp:, weight_kg:, volume_m3:)
    eligible = true
    reasons = []

    if pp.max_weight_kg.present? && weight_kg.to_f > pp.max_weight_kg.to_f
      eligible = false
      reasons << "max_weight_exceeded"
    end
    if pp.max_volume_m3.present? && volume_m3.to_f > pp.max_volume_m3.to_f
      eligible = false
      reasons << "max_volume_exceeded"
    end

    { eligible: eligible, reasons: reasons }
  end

  def self.europost_cart_eligibility(parcel_result:)
    return { eligible: false, reason: normalize_ineligible_reason(parcel_result[:ineligible_reason]) } unless parcel_result[:eligible_for_europost]

    points = PickupPoint.active.where(provider: "europost")
    return { eligible: false, reason: "europost_pickup_points_unavailable" } if points.empty?

    eligible = points.any? { |pp| pickup_point_supports_parcels?(pp: pp, parcels: parcel_result[:parcels]) }

    eligible ? { eligible: true, reason: nil } : { eligible: false, reason: "europost_pickup_points_constraints_failed" }
  end

  def self.normalize_ineligible_reason(reason)
    return "missing_vgh_data" if reason.to_s.start_with?("missing_")

    reason || "missing_vgh_data"
  end

  def self.pickup_point_supports_parcels?(pp:, parcels:)
    Array(parcels).all? do |parcel|
      pickup_point_eligibility(
        pp: pp,
        weight_kg: parcel[:weight_kg],
        volume_m3: parcel[:volume_m3]
      )[:eligible]
    end
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
