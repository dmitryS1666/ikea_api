# frozen_string_literal: true

# Builds the public cart totals contract for the frontend "Ваш заказ" block.
#
# Turnkey product prices already include D_IKEA and WC. Those amounts stay in
# items_total_byn / subtotal_new_byn as a breakdown only and must not be added
# again via delivery_total_byn.
#
# Public cart formula before a checkout last-mile method is selected:
#
#   final_total_byn =
#     items_total_byn
#     - discount_total_byn
#     + customs_total_byn
#     + local_delivery_total_byn
#
# items_total_byn / subtotal_new_byn are the turnkey goods amount BEFORE promo.
# local_delivery_total_byn is 0 until Europost/courier/IKEYA last-mile is chosen.
# Customs is part of the payable total.
class CartDisplayTotalsService
  class << self
    def for_summary(totals)
      raw = (totals || {}).with_indifferent_access

      discount_total_byn = money(raw[:discount_total_byn])
      customs_total_byn = money(raw[:customs_total_byn])
      local_delivery_total_byn = money(raw[:local_delivery_total_byn] || raw[:delivery_method_byn])
      delivery_to_belarus_byn = money(raw[:delivery_to_belarus_byn])
      delivery_poland_byn = money(raw[:delivery_poland_byn])

      items_total_byn = money(first_present(raw, :items_total_byn, :subtotal_new_byn))
      subtotal_new_byn = items_total_byn
      delivery_total_byn = local_delivery_total_byn
      total_byn = [
        items_total_byn - discount_total_byn + customs_total_byn + local_delivery_total_byn,
        0.0
      ].max.round(2)

      raw.to_h.symbolize_keys.merge(
        subtotal_new_byn: subtotal_new_byn,
        items_total_byn: items_total_byn,
        delivery_to_belarus_byn: delivery_to_belarus_byn,
        delivery_poland_byn: delivery_poland_byn,
        delivery_method_byn: local_delivery_total_byn,
        local_delivery_total_byn: local_delivery_total_byn,
        delivery_total_byn: delivery_total_byn,
        total_byn: total_byn,
        final_total_byn: total_byn,
        discount_total_byn: discount_total_byn,
        customs_total_byn: customs_total_byn,
        customs_duty_byn: money(raw[:customs_duty_byn]),
        customs_fee_byn: money(raw[:customs_fee_byn]),
        total_weight_kg: raw[:total_weight_kg].to_f
      )
    end

    private

    def first_present(raw, *keys)
      keys.each do |key|
        return raw[key] if raw.key?(key) || raw.key?(key.to_s)
      end
      0
    end

    def money(value)
      value.to_f.round(2)
    end
  end
end
