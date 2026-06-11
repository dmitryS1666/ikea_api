# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckoutPricingPresenter do
  let(:date) { Date.current }

  before do
    CalculatorSetting.initialize_defaults
    ExchangeRate.create!(
      date: date,
      currency_code: "PLN",
      rate: 0.85,
      official_rate: 0.85,
      scale: 1
    )
    ExchangeRate.create!(
      date: date,
      currency_code: "EUR",
      rate: 3.5,
      official_rate: 3.5,
      scale: 1
    )
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PRICE_CHEAP_THRESHOLD_PLN", anything).and_return("150")
  end

  it "exposes storefront line prices without Belarus delivery in totals breakdown" do
    user = create(:user)
    product = create(
      :product,
      sku: "SKU-CHK-PRES",
      price: 500.0,
      weight: 15.0,
      delivery_cost: 50.0,
      quantity: 5,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "15 кг", "count" => 1, "width" => "80 см", "height" => "40 см", "length" => "150 см" }
            ]
          }
        }
      }
    )
    allow(Products::WeightExtractor).to receive(:packaging_weight_kg_for_product).and_return(15.0)

    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = CartPricingService.call(cart: Cart.find(cart.id))
    summary = described_class.for_pricing(pricing)
    item = summary[:items].first

    expect(pricing[:items].first[:line_total_byn_checkout]).to be > pricing[:items].first[:line_total_byn]
    expect(summary[:totals][:subtotal_new_byn].to_f + summary[:totals][:delivery_to_belarus_byn].to_f).to be_within(0.02).of(
      summary[:totals][:total_byn].to_f + summary[:totals][:discount_total_byn].to_f
    )
  end
  it "shows selected delivery method in draft payable total even if saved draft total is stale" do
    order = build_stubbed(
      :order,
      checkout_draft: true,
      delivery_type: "courier",
      total_amount: 775.70,
      delivery_price: 133.82,
      address_json: {
        "delivery" => {
          "prices" => {
            "delivery_price_byn" => "53.87",
            "delivery_to_belarus_price_byn" => "79.95",
            "total_delivery_price_byn" => "133.82"
          }
        }
      }
    )
    pricing = {
      items: [],
      totals: {
        subtotal_new_byn: 695.75,
        discount_total_byn: 0.0,
        delivery_to_belarus_byn: 79.95,
        delivery_total_byn: 79.95,
        total_byn: 775.70,
        final_total_byn: 775.70,
        total_weight_kg: 66.3
      },
      promo: {},
      meta: {}
    }

    summary = described_class.for_order(order, pricing: pricing)

    expect(summary.dig(:totals, :delivery_to_belarus_byn)).to eq("79.95")
    expect(summary.dig(:totals, :delivery_method_byn)).to eq("53.87")
    expect(summary.dig(:totals, :delivery_total_byn)).to eq("133.82")
    expect(summary.dig(:totals, :total_byn)).to eq("829.57")
    expect(summary.dig(:totals, :final_total_byn)).to eq("829.57")
  end

end
