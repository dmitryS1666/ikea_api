# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckoutService, "checkout delivery totals" do
  include CheckoutDeliveryTotalsHelpers

  let(:date) { Date.current }
  let(:user) { create(:user) }
  let(:product) do
    create(
      :product,
      sku: "SKU-CHK-TOTALS-#{SecureRandom.hex(3)}",
      quantity: 10,
      price: 120.0,
      weight: 8.0,
      delivery_cost: 15.0,
      package_volume: 0.02,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "8 кг", "count" => 1, "width" => "20 см", "height" => "30 см", "length" => "40 см" }
            ]
          }
        }
      }
    )
  end

  before do
    CalculatorSetting.initialize_defaults
    ExchangeRate.create!(date: date, currency_code: "PLN", rate: 0.85, official_rate: 0.85, scale: 1)
    ExchangeRate.create!(date: date, currency_code: "EUR", rate: 3.5, official_rate: 3.5, scale: 1)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PRICE_CHEAP_THRESHOLD_PLN", anything).and_return("150")
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
  end

  def build_pricing
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 2)
    CartPricingService.call(cart: cart)
  end

  describe ".checkout_delivery_prices" do
    it "keeps cart Belarus delivery and adds only the selected method component" do
      pricing = build_pricing
      cart_belarus = CartDisplayTotalsService.for_summary(pricing[:totals])[:delivery_to_belarus_byn].to_f

      normalized = described_class.send(
        :checkout_delivery_prices,
        pricing: pricing,
        raw_prices: {
          delivery_price_byn: 12.43,
          delivery_to_belarus_price_byn: cart_belarus - 2.0,
          total_delivery_price_byn: 99.0
        }
      )

      expect(normalized[:delivery_to_belarus_price_byn]).to eq(cart_belarus)
      expect(normalized[:delivery_price_byn]).to eq(12.43)
      expect(normalized[:total_delivery_price_byn]).to eq((cart_belarus + 12.43).round(2))
    end
  end

  describe ".checkout_total_amount" do
    it "includes Belarus delivery and method delivery in payable total" do
      pricing = build_pricing
      display = CartDisplayTotalsService.for_summary(pricing[:totals])
      belarus = display[:delivery_to_belarus_byn].to_f
      method = 18.5

      total = described_class.send(
        :checkout_total_amount,
        pricing: pricing,
        prices: { total_delivery_price_byn: belarus + method }
      )

      expected = (display[:subtotal_new_byn].to_f - display[:discount_total_byn].to_f + belarus + method).round(2)
      expect(total).to eq(expected)
      expect(total).not_to be_within(0.02).of(display[:subtotal_new_byn].to_f + method)
    end
  end

  describe ".sync_draft_order_totals!" do
    it "writes order.total_amount and delivery_price from pricing summary" do
      pricing = build_pricing
      cart = user.cart || create(:cart, user: user)
      cart.cart_items.destroy_all
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      order = create(
        :order,
        user: user,
        checkout_draft: true,
        status: :created,
        total_amount: 1.0,
        delivery_price: 1.0,
        delivery_type: nil
      )
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 10.0)

      summary = CheckoutPricingPresenter.for_order(order, pricing: CartPricingService.call_from_order(order: order))
      described_class.sync_draft_order_totals!(order, summary)
      order.reload

      expect_order_amounts_match_pricing!(order: order, totals: summary[:totals])
    end
  end

  describe ".draft_pricing_response" do
    it "returns presenter summary and syncs persisted draft amounts" do
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
      order = create(
        :order,
        user: user,
        checkout_draft: true,
        status: :created,
        total_amount: 999.0,
        delivery_price: 999.0
      )
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 10.0)

      summary = described_class.draft_pricing_response(order)
      order.reload

      expect(order.total_amount.to_f).to be_within(0.02).of(summary.dig(:totals, :total_byn).to_f)
      expect(order.delivery_price.to_f).to be_within(0.02).of(summary.dig(:totals, :delivery_total_byn).to_f)
      expect(summary.dig(:totals, :delivery_method_byn)).to eq("0.00")
    end
  end

  describe ".enrich_delivery_methods_with_prices!" do
    it "uses cart Belarus delivery in method price breakdown" do
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
      pricing = CartPricingService.call(cart: cart)
      cart_belarus = CartDisplayTotalsService.for_summary(pricing[:totals])[:delivery_to_belarus_byn].to_f

      order = create(
        :order,
        user: user,
        checkout_draft: true,
        status: :created,
        total_amount: 100.0,
        delivery_price: cart_belarus
      )
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 10.0)

      allow(described_class).to receive(:delivery_prices_for).and_return(
        delivery_price_byn: 12.43,
        delivery_to_belarus_price_byn: cart_belarus - 3.0,
        total_delivery_price_byn: cart_belarus - 3.0 + 12.43
      )

      options = DeliveryOptionsService.call(CartPricingService.order_as_cart(order))
      enriched = described_class.send(:enrich_delivery_methods_with_prices!, options, order)
      pickup = enriched[:methods].find { |m| m[:code] == DeliveryTypeNormalizer::EUROPOST_PICKUP }

      expect(pickup[:delivery_to_belarus_price_byn]).to eq(cart_belarus)
      expect(pickup[:delivery_price_byn]).to eq(12.43)
      expect(pickup[:total_delivery_price_byn]).to eq((cart_belarus + 12.43).round(2))
    end

    it "keeps cart Belarus delivery with real finance quotes for every available method" do
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
      pricing = CartPricingService.call(cart: cart)
      cart_belarus = CartDisplayTotalsService.for_summary(pricing[:totals])[:delivery_to_belarus_byn].to_f

      order = create(
        :order,
        user: user,
        checkout_draft: true,
        status: :created,
        total_amount: 100.0,
        delivery_price: cart_belarus
      )
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 10.0)

      options = DeliveryOptionsService.call(CartPricingService.order_as_cart(order))
      enriched = described_class.send(:enrich_delivery_methods_with_prices!, options, order)

      priced_methods = Array(enriched[:methods]).select { |method| method[:available] && method[:total_delivery_price_byn] }
      expect(priced_methods).not_to be_empty

      priced_methods.each do |method|
        expect(method[:delivery_to_belarus_price_byn]).to eq(cart_belarus)
        expect(method[:total_delivery_price_byn]).to eq((cart_belarus + method[:delivery_price_byn].to_f).round(2))
      end
    end
  end

  describe ".refresh_draft_order!" do
    it "resets draft totals to cart-only amounts when delivery is cleared" do
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
      pricing = CartPricingService.call(cart: cart)
      display = CartDisplayTotalsService.for_summary(pricing[:totals])

      order = create(
        :order,
        user: user,
        checkout_draft: true,
        status: :created,
        delivery_type: "courier",
        total_amount: display[:subtotal_new_byn].to_f + 18.5,
        delivery_price: 18.5,
        address_json: {
          "delivery" => {
            "prices" => {
              "delivery_price_byn" => "18.50",
              "total_delivery_price_byn" => "18.50"
            }
          }
        }
      )
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 10.0)
      checkout_cart = CartPricingService.order_as_cart(order)

      described_class.send(
        :refresh_draft_order!,
        order: order,
        cart: cart,
        checkout_cart: checkout_cart,
        pricing: pricing,
        params: {}
      )
      order.reload

      expect(order.delivery_type).to be_nil
      expect(order.total_amount.to_f).to be_within(0.02).of(display[:total_byn].to_f)
      expect(order.delivery_price.to_f).to be_within(0.02).of(display[:delivery_to_belarus_byn].to_f)
      expect(order.total_amount.to_f).not_to be_within(0.02).of(display[:subtotal_new_byn].to_f + 18.5)
    end
  end
end
