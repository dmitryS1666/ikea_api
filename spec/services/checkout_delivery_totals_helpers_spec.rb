# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckoutDeliveryTotalsHelpers do
  include described_class

  describe "expect_checkout_delivery_totals_contract!" do
    it "passes for a valid checkout breakdown" do
      expect do
        expect_checkout_delivery_totals_contract!(
          {
            "items_total_byn" => "191.73",
            "subtotal_new_byn" => "191.73",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "12.43",
            "delivery_total_byn" => "12.43",
            "customs_total_byn" => "0.00",
            "total_byn" => "204.16"
          },
          delivery: {
            "delivery_price_byn" => "12.43",
            "delivery_to_belarus_price_byn" => "6.01",
            "total_delivery_price_byn" => "12.43"
          }
        )
      end.not_to raise_error
    end

    it "detects adding WC twice into delivery_total" do
      expect do
        expect_checkout_delivery_totals_contract!(
          {
            "items_total_byn" => "191.73",
            "subtotal_new_byn" => "191.73",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "12.43",
            "delivery_total_byn" => "18.44",
            "customs_total_byn" => "0.00",
            "total_byn" => "210.17"
          }
        )
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end
  end

  describe "expect_cart_stage_totals_contract!" do
    it "passes for cart stage totals without last-mile" do
      expect do
        expect_cart_stage_totals_contract!(
          {
            "items_total_byn" => "191.73",
            "subtotal_new_byn" => "191.73",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "0.00",
            "delivery_total_byn" => "0.00",
            "customs_total_byn" => "0.00",
            "total_byn" => "191.73"
          }
        )
      end.not_to raise_error
    end
  end
end
