# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckoutDeliveryTotalsHelpers do
  include described_class

  describe "expect_checkout_delivery_totals_contract!" do
    it "passes for a valid checkout breakdown" do
      expect do
        expect_checkout_delivery_totals_contract!(
          {
            "subtotal_new_byn" => "185.72",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "12.43",
            "delivery_total_byn" => "18.44",
            "total_byn" => "204.16"
          },
          delivery: {
            "delivery_price_byn" => "12.43",
            "delivery_to_belarus_price_byn" => "6.01",
            "total_delivery_price_byn" => "18.44"
          }
        )
      end.not_to raise_error
    end

    it "detects the method-only total regression" do
      expect do
        expect_checkout_delivery_totals_contract!(
          {
            "subtotal_new_byn" => "185.72",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "12.43",
            "delivery_total_byn" => "12.43",
            "total_byn" => "198.15"
          }
        )
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end
  end

  describe "expect_cart_stage_totals_contract!" do
    it "passes for cart stage totals without method delivery" do
      expect do
        expect_cart_stage_totals_contract!(
          {
            "subtotal_new_byn" => "185.72",
            "discount_total_byn" => "0.00",
            "delivery_to_belarus_byn" => "6.01",
            "delivery_method_byn" => "0.00",
            "delivery_total_byn" => "6.01",
            "total_byn" => "191.73"
          }
        )
      end.not_to raise_error
    end
  end
end
