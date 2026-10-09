# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckoutPricingPresenter do
  let(:date) { Date.current }

  before do
    CalculatorSetting.initialize_defaults
    ExchangeRate.create!(date: date, currency_code: "PLN", rate: 0.85, official_rate: 0.85, scale: 1)
    ExchangeRate.create!(date: date, currency_code: "EUR", rate: 3.5, official_rate: 3.5, scale: 1)
  end

  it "keeps WC inside items and exposes last-mile separately" do
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
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = CartPricingService.call(cart: Cart.find(cart.id))
    summary = described_class.for_pricing(pricing)
    item = summary[:items].first

    expect(pricing[:items].first[:line_total_byn_checkout]).to eq(pricing[:items].first[:line_total_byn])
    expect(summary[:totals][:total_byn].to_f).to be_within(0.02).of(
      summary[:totals][:subtotal_new_byn].to_f -
        summary[:totals][:discount_total_byn].to_f +
        summary[:totals][:customs_total_byn].to_f
    )
    expect(summary.dig(:totals, :delivery_method_byn)).to eq("0.00")
    expect(item[:pricing][:line_total_new_byn]).to be_present
  end

  it "adds only last-mile to draft payable total" do
    order = build_stubbed(
      :order,
      checkout_draft: true,
      delivery_type: "courier",
      total_amount: 749.62,
      delivery_price: 53.87,
      address_json: {
        "delivery" => {
          "prices" => {
            "delivery_price_byn" => "53.87",
            "delivery_to_belarus_price_byn" => "79.95",
            "total_delivery_price_byn" => "53.87"
          }
        }
      }
    )
    pricing = {
      items: [],
      totals: {
        items_total_byn: 695.75,
        subtotal_new_byn: 695.75,
        discount_total_byn: 0.0,
        delivery_to_belarus_byn: 79.95,
        customs_total_byn: 0.0,
        total_weight_kg: 66.3
      },
      promo: {},
      meta: {}
    }

    summary = described_class.for_order(order, pricing: pricing)

    expect(summary.dig(:totals, :delivery_to_belarus_byn)).to eq("79.95")
    expect(summary.dig(:totals, :delivery_method_byn)).to eq("53.87")
    expect(summary.dig(:totals, :delivery_total_byn)).to eq("53.87")
    expect(summary.dig(:totals, :total_byn)).to eq("749.62")
  end

  it "does not add WC again when snapshot stores method-only delivery" do
    order = build_stubbed(
      :order,
      checkout_draft: true,
      delivery_type: "europost_pickup",
      total_amount: 259.36,
      delivery_price: 63.04,
      address_json: {
        "delivery" => {
          "prices" => {
            "delivery_price_byn" => "63.04",
            "delivery_to_belarus_price_byn" => "40.96",
            "total_delivery_price_byn" => "63.04"
          }
        }
      }
    )
    pricing = {
      items: [],
      totals: {
        items_total_byn: 196.32,
        subtotal_new_byn: 196.32,
        discount_total_byn: 0.0,
        delivery_to_belarus_byn: 40.96,
        customs_total_byn: 0.0,
        total_weight_kg: 17.3
      },
      promo: {},
      meta: {}
    }

    summary = described_class.for_order(order, pricing: pricing)

    expect(summary.dig(:totals, :delivery_method_byn)).to eq("63.04")
    expect(summary.dig(:totals, :delivery_total_byn)).to eq("63.04")
    expect(summary.dig(:totals, :total_byn)).to eq("259.36")
  end

  it "uses persisted order total for finalized orders" do
    order = build_stubbed(
      :order,
      checkout_draft: false,
      delivery_type: "courier",
      total_amount: 500.0,
      delivery_price: 20.0,
      address_json: {
        "delivery" => {
          "prices" => {
            "delivery_price_byn" => "20.00",
            "delivery_to_belarus_price_byn" => "60.00",
            "total_delivery_price_byn" => "20.00"
          }
        }
      }
    )
    pricing = {
      items: [],
      totals: {
        items_total_byn: 400.0,
        subtotal_new_byn: 400.0,
        discount_total_byn: 0.0,
        delivery_to_belarus_byn: 60.0,
        customs_total_byn: 0.0,
        total_weight_kg: 10.0
      },
      promo: {},
      meta: {}
    }

    summary = described_class.for_order(order, pricing: pricing)

    expect(summary.dig(:totals, :total_byn)).to eq("500.00")
    expect(summary.dig(:totals, :final_total_byn)).to eq("500.00")
  end
end
