# frozen_string_literal: true

# Сводка цен для POST /api/v1/delivery/calculate и выдачи цен в списке ПВЗ.
# Для europost_pickup сегмент «до Беларуси» при успешном ответе Европочты берётся из
# postal/payment/calculate; логистика по РБ (wc) остаётся по внутренним таблицам.
class DeliveryCalculateFinance
  def self.call(normalized_delivery_type:, weight_kg:, pln_rate_with_buffer:, parcels: nil, pickup_point_id: nil, address: nil)
    poland_pln = PolandDeliveryService.calculate(weight_kg)
    belarus_pln = BelarusDeliveryService.calculate(weight_kg)
    poland_byn = (poland_pln * pln_rate_with_buffer).round(2)
    belarus_byn = (belarus_pln * pln_rate_with_buffer).round(2)
    total_internal_pln = poland_pln + belarus_pln
    total_internal_byn = (poland_byn + belarus_byn).round(2)

    europost_quote = nil
    delivery_poland_component_byn =
      case normalized_delivery_type
      when DeliveryTypeNormalizer::IKEYA_DELIVERY
        0.0
      when DeliveryTypeNormalizer::EUROPOST_PICKUP
        europost_quote = EuropostPostalPaymentQuote.call(
          weight_kg: weight_kg,
          pln_rate_with_buffer: pln_rate_with_buffer,
          parcels: parcels,
          pickup_point_id: pickup_point_id,
          delivery_kind: :pickup
        )
        europost_quote[:success] ? europost_quote[:postal_total_byn].to_f : poland_byn
      when DeliveryTypeNormalizer::COURIER
        europost_quote = EuropostPostalPaymentQuote.call(
          weight_kg: weight_kg,
          pln_rate_with_buffer: pln_rate_with_buffer,
          parcels: parcels,
          delivery_kind: :courier,
          address: address
        )
        europost_quote[:success] ? europost_quote[:postal_total_byn].to_f : poland_byn
      else
        poland_byn
      end

    total_delivery_byn = (delivery_poland_component_byn + belarus_byn).round(2)

    {
      poland_delivery_pln: poland_pln,
      belarus_delivery_pln: belarus_pln,
      poland_delivery_byn: poland_byn,
      belarus_delivery_byn: belarus_byn,
      total_delivery_pln: total_internal_pln,
      total_internal_byn: total_internal_byn,
      delivery_price_byn: delivery_poland_component_byn,
      delivery_to_belarus_price_byn: belarus_byn,
      total_delivery_price_byn: total_delivery_byn,
      base_cost_byn: total_internal_byn,
      europost_quote: europost_quote,
      pricing_source: pricing_source(normalized_delivery_type, europost_quote)
    }
  end

  def self.pricing_source(normalized_delivery_type, europost_quote)
    case normalized_delivery_type
    when DeliveryTypeNormalizer::IKEYA_DELIVERY
      "internal_ikeya_poland_zero"
    when DeliveryTypeNormalizer::EUROPOST_PICKUP, DeliveryTypeNormalizer::COURIER
      if europost_quote&.dig(:success)
        "europost_api"
      elsif europost_quote&.dig(:reason) == "europost_token_missing"
        "internal_europost_token_missing"
      else
        "internal_europost_fallback"
      end
    else
      "internal_weight_tables"
    end
  end
  private_class_method :pricing_source
end
