# frozen_string_literal: true

# Форматирует расчёт CartPricingService для checkout так же, как блок totals в корзине.
class CheckoutPricingPresenter
  DELIVERY_TITLES = {
    DeliveryTypeNormalizer::EUROPOST_PICKUP => "ПВЗ Европочты",
    DeliveryTypeNormalizer::COURIER => "Курьерская доставка",
    DeliveryTypeNormalizer::IKEYA_DELIVERY => "Доставка IKEYA"
  }.freeze

  class << self
    def for_order(order, pricing: nil)
      pricing ||= CartPricingService.call_from_order(order: order)
      summary = for_pricing(pricing)
      return summary unless summary && order.delivery_type.present?

      apply_order_delivery_totals!(summary, order)
      summary
    end

    def for_pricing(pricing)
      return nil if pricing.blank?

      totals = CartDisplayTotalsService.for_summary(pricing[:totals])
      discount = totals[:discount_total_byn].to_f
      subtotal_old = totals[:subtotal_old_byn]
      subtotal_old = (totals[:subtotal_new_byn].to_f + discount).round(2) if subtotal_old.nil?

      {
        items: Array(pricing[:items]).map { |line| format_line(line) },
        totals: {
          items_total_byn: format_byn(totals[:items_total_byn]),
          subtotal_old_byn: format_byn(subtotal_old),
          subtotal_new_byn: format_byn(totals[:subtotal_new_byn]),
          discount_total_byn: format_byn(totals[:discount_total_byn]),
          delivery_poland_byn: format_byn(totals[:delivery_poland_byn]),
          delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
          delivery_total_byn: format_byn(totals[:delivery_total_byn]),
          total_byn: format_byn(totals[:total_byn]),
          final_total_byn: format_byn(totals[:final_total_byn] || totals[:total_byn]),
          customs_total_byn: format_byn(totals[:customs_total_byn]),
          customs_duty_byn: format_byn(totals[:customs_duty_byn]),
          customs_fee_byn: format_byn(totals[:customs_fee_byn]),
          total_weight_kg: totals[:total_weight_kg].to_f
        },
        promo: pricing[:promo],
        meta: pricing[:meta]
      }
    end

    private

    def apply_order_delivery_totals!(summary, order)
      snapshot_prices = delivery_prices_from_order(order)
      total_delivery = order.delivery_price.to_f

      summary[:totals][:delivery_total_byn] = format_byn(total_delivery)
      summary[:totals][:total_byn] = format_byn(order.total_amount)
      summary[:totals][:final_total_byn] = format_byn(order.total_amount)

      if snapshot_prices
        summary[:totals][:delivery_poland_byn] = snapshot_prices[:delivery_price_byn]
        summary[:totals][:delivery_to_belarus_byn] = snapshot_prices[:delivery_to_belarus_price_byn]
      end

      summary[:delivery] = {
        type: order.delivery_type,
        title: DELIVERY_TITLES[order.delivery_type] || order.delivery_type,
        delivery_price_byn: snapshot_prices&.dig(:delivery_price_byn) || format_byn(total_delivery),
        delivery_to_belarus_price_byn: snapshot_prices&.dig(:delivery_to_belarus_price_byn),
        total_delivery_price_byn: format_byn(total_delivery)
      }.compact
    end

    def delivery_prices_from_order(order)
      delivery = order.address_json.is_a?(Hash) ? order.address_json["delivery"] || order.address_json[:delivery] : nil
      prices = delivery.is_a?(Hash) ? delivery["prices"] || delivery[:prices] : nil
      return nil unless prices.is_a?(Hash)

      {
        delivery_price_byn: prices["delivery_price_byn"] || prices[:delivery_price_byn],
        delivery_to_belarus_price_byn: prices["delivery_to_belarus_price_byn"] || prices[:delivery_to_belarus_price_byn],
        total_delivery_price_byn: prices["total_delivery_price_byn"] || prices[:total_delivery_price_byn]
      }.compact
    end

    def format_line(line)
      qty = [line[:quantity].to_i, 1].max
      unit_before = line[:unit_price_byn_before_discount].to_f
      unit_after = line[:unit_price_byn].to_f

      {
        sku: line[:sku],
        quantity: qty,
        pricing: {
          unit_price_old_byn: format_byn(unit_before),
          unit_price_new_byn: format_byn(unit_after),
          unit_discount_byn: format_byn(line[:unit_discount_byn]),
          line_total_old_byn: format_byn(unit_before * qty),
          line_total_new_byn: format_byn(line[:line_total_byn]),
          line_discount_byn: format_byn(line[:line_discount_byn]),
          promo_applied: line[:promo_applied] || false,
          promo_code: line[:promo_code]
        }
      }
    end

    def format_byn(value)
      format("%.2f", value.to_f)
    end
  end
end
