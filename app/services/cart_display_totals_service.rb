# frozen_string_literal: true

# Builds the public cart totals contract for the frontend "Ваш заказ" block.
#
# CartPricingService keeps internal totals used by checkout/order calculations. In
# cart/summary the frontend expects delivery_total_byn to contain the visible
# Belarus delivery price because that price is already included in total_byn.
#
# Public cart formula before a checkout delivery method is selected:
#
#   total_byn = subtotal_new_byn + delivery_total_byn - discount_total_byn
#
# where delivery_total_byn == delivery_to_belarus_byn. After a checkout delivery
# method is selected, POST /api/v1/delivery/calculate returns delivery_total_byn
# as delivery_to_belarus + selected local delivery.
#
# Customs duty stays informational and is not included in total_byn.
class CartDisplayTotalsService
  class << self
    def for_summary(totals)
      raw = (totals || {}).with_indifferent_access

      total_byn = money(raw[:total_byn])
      discount_total_byn = money(raw[:discount_total_byn])
      delivery_to_belarus_byn = money(raw[:delivery_to_belarus_byn])

      # In cart/summary no pickup/courier/IKEYA local delivery is selected yet,
      # but the frontend expects delivery_total_byn to show the delivery to
      # Belarus that is already embedded in total_byn.
      delivery_total_byn = delivery_to_belarus_byn

      subtotal_new_byn = [
        total_byn + discount_total_byn - delivery_total_byn,
        0.0
      ].max.round(2)

      raw.to_h.symbolize_keys.merge(
        subtotal_new_byn: subtotal_new_byn,
        items_total_byn: subtotal_new_byn,
        delivery_to_belarus_byn: delivery_to_belarus_byn,
        delivery_total_byn: delivery_total_byn,
        total_byn: total_byn,
        final_total_byn: total_byn,
        discount_total_byn: discount_total_byn,
        customs_total_byn: money(raw[:customs_total_byn]),
        customs_duty_byn: money(raw[:customs_duty_byn]),
        customs_fee_byn: money(raw[:customs_fee_byn]),
        total_weight_kg: raw[:total_weight_kg].to_f
      )
    end

    private

    def money(value)
      value.to_f.round(2)
    end
  end
end
