# frozen_string_literal: true

module CheckoutDeliveryTotalsHelpers
  # Public checkout/cart contract:
  #   delivery_total_byn = delivery_to_belarus_byn + delivery_method_byn
  #   total_byn = subtotal_new_byn - discount_total_byn + delivery_total_byn
  def expect_checkout_delivery_totals_contract!(totals, delivery: nil)
    totals = totals.stringify_keys
    subtotal = totals["subtotal_new_byn"].to_f
    discount = totals["discount_total_byn"].to_f
    belarus = totals["delivery_to_belarus_byn"].to_f
    method = totals.fetch("delivery_method_byn", "0").to_f
    delivery_total = totals["delivery_total_byn"].to_f
    total = totals["total_byn"].to_f

    expect(delivery_total).to be_within(0.02).of(belarus + method),
                              "delivery_total_byn must equal belarus + method (#{belarus} + #{method})"
    expect(subtotal - discount + delivery_total).to be_within(0.02).of(total),
                                                    "total_byn must equal subtotal - discount + delivery_total"

    if delivery
      delivery = delivery.stringify_keys
      expect(delivery["delivery_to_belarus_price_byn"].to_f).to be_within(0.02).of(belarus)
      expect(delivery["delivery_price_byn"].to_f).to be_within(0.02).of(method)
      expect(delivery["total_delivery_price_byn"].to_f).to be_within(0.02).of(delivery_total)
    end

    guard_against_method_only_total_bug!(subtotal: subtotal, belarus: belarus, method: method, total: total)
  end

  def expect_cart_stage_totals_contract!(totals)
    totals = totals.stringify_keys
    subtotal = totals["subtotal_new_byn"].to_f
    discount = totals["discount_total_byn"].to_f
    belarus = totals["delivery_to_belarus_byn"].to_f
    total = totals["total_byn"].to_f
    method = totals.fetch("delivery_method_byn", "0").to_f

    expect(method).to eq(0.0), "cart stage must not expose a delivery method component"
    expect(subtotal - discount + belarus).to be_within(0.02).of(total)
    expect(totals["delivery_total_byn"].to_f).to be_within(0.02).of(belarus)
  end

  def expect_order_amounts_match_pricing!(order:, totals:, order_payload: nil)
    totals = totals.stringify_keys
    expect(order.total_amount.to_f).to be_within(0.02).of(totals["total_byn"].to_f)
    expect(order.delivery_price.to_f).to be_within(0.02).of(totals["delivery_total_byn"].to_f)

    return unless order_payload

    payload_total = order_payload["total_amount"] || order_payload.dig("data", "attributes", "total_amount")
    expect(payload_total.to_f).to be_within(0.02).of(totals["total_byn"].to_f)
  end

  private

  def guard_against_method_only_total_bug!(subtotal:, belarus:, method:, total:)
    return unless belarus.positive? && method.positive?

    wrong_total = (subtotal + method).round(2)
    correct_total = (subtotal + belarus + method).round(2)

    expect(total).to be_within(0.02).of(correct_total)
    expect(total).not_to be_within(0.02).of(wrong_total),
                         "total looks like subtotal + method only (Belarus delivery ignored)"
  end
end

RSpec.configure do |config|
  config.include CheckoutDeliveryTotalsHelpers
end
