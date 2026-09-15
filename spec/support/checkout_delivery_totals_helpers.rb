# frozen_string_literal: true

module CheckoutDeliveryTotalsHelpers
  # Public checkout/cart contract after the turnkey pricing change:
  #   delivery_total_byn = last-mile only (not WC / D_IKEA)
  #   total_byn = items_total_byn - discount_total_byn + customs_total_byn + delivery_total_byn
  def expect_checkout_delivery_totals_contract!(totals, delivery: nil)
    totals = totals.stringify_keys
    items = (totals["items_total_byn"] || totals["subtotal_new_byn"]).to_f
    discount = totals["discount_total_byn"].to_f
    customs = totals["customs_total_byn"].to_f
    method = totals.fetch("delivery_method_byn", totals["local_delivery_total_byn"] || "0").to_f
    delivery_total = totals["delivery_total_byn"].to_f
    total = totals["total_byn"].to_f

    expect(delivery_total).to be_within(0.02).of(method),
                              "delivery_total_byn must equal last-mile method only (#{method})"
    expect(items - discount + customs + delivery_total).to be_within(0.02).of(total),
                                                           "total_byn must equal items - discount + customs + last-mile"

    if delivery
      delivery = delivery.stringify_keys
      expect(delivery["delivery_price_byn"].to_f).to be_within(0.02).of(method)
      expect(delivery["total_delivery_price_byn"].to_f).to be_within(0.02).of(delivery_total)
    end
  end

  def expect_cart_stage_totals_contract!(totals)
    totals = totals.stringify_keys
    items = (totals["items_total_byn"] || totals["subtotal_new_byn"]).to_f
    discount = totals["discount_total_byn"].to_f
    customs = totals["customs_total_byn"].to_f
    total = totals["total_byn"].to_f
    method = totals.fetch("delivery_method_byn", "0").to_f

    expect(method).to eq(0.0), "cart stage must not expose a delivery method component"
    expect(items - discount + customs).to be_within(0.02).of(total)
    expect(totals["delivery_total_byn"].to_f).to be_within(0.02).of(0.0)
  end

  def expect_order_amounts_match_pricing!(order:, totals:, order_payload: nil)
    totals = totals.stringify_keys
    expect(order.total_amount.to_f).to be_within(0.02).of(totals["total_byn"].to_f)
    expect(order.delivery_price.to_f).to be_within(0.02).of(totals["delivery_total_byn"].to_f)

    return unless order_payload

    payload_total = order_payload["total_amount"] || order_payload.dig("data", "attributes", "total_amount")
    expect(payload_total.to_f).to be_within(0.02).of(totals["total_byn"].to_f)
  end
end

RSpec.configure do |config|
  config.include CheckoutDeliveryTotalsHelpers
end
