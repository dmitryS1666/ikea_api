# frozen_string_literal: true

require "rails_helper"

RSpec.describe "IKEYA new pricing formula" do
  let(:pln_rate) { 1.0 }
  let(:eur_rate) { 4.0 }
  let(:buffer) { 1.05 }

  before do
    CalculatorSetting.initialize_defaults
  end

  def unit(**kwargs)
    PriceCalculationService.unit_breakdown(
      ikea_price_pln: kwargs.fetch(:ikea),
      price_addon_pln: kwargs.fetch(:addon, 0),
      weight_kg: kwargs.fetch(:weight),
      d_ikea_pln: kwargs.fetch(:d_ikea),
      pln_rate: kwargs.fetch(:pln_rate, pln_rate),
      eur_rate: kwargs.fetch(:eur_rate, eur_rate),
      buffer: kwargs.fetch(:buffer, buffer)
    )
  end

  def priced_product(**attrs)
    weight = attrs.delete(:weight) || 10.0
    create(
      :product,
      {
        price: 100.0,
        weight: weight,
        delivery_cost: 20.0,
        quantity: 10,
        price_addon_pln: 0,
        full_attributes: {
          "dimensions_map" => {
            "packaging" => {
              "details" => [
                { "weight" => "#{weight} кг", "count" => 1, "width" => "20 см", "height" => "30 см", "length" => "40 см" }
              ]
            }
          }
        }
      }.merge(attrs)
    )
  end

  def seed_rates!
    ExchangeRate.create!(date: Date.current, currency_code: "PLN", rate: pln_rate, official_rate: pln_rate, scale: 1)
    ExchangeRate.create!(date: Date.current, currency_code: "EUR", rate: eur_rate, official_rate: eur_rate, scale: 1)
  end

  describe "A. addon" do
    it "IKEA 100 + addon 20 => P 120, goods 156" do
      result = unit(ikea: 100, addon: 20, weight: 10, d_ikea: 0)
      expect(result[:effective_price_p_pln]).to eq(BigDecimal("120"))
      expect(result[:goods_pln]).to eq(BigDecimal("156"))
    end
  end

  describe "B. negative addon" do
    it "uses max(0, addon) so P stays 100" do
      result = unit(ikea: 100, addon: -50, weight: 10, d_ikea: 0)
      expect(result[:effective_price_p_pln]).to eq(BigDecimal("100"))
      expect(result[:goods_pln]).to eq(BigDecimal("130"))
    end
  end

  describe "C. addon crosses 150" do
    it "uses k-formula when P = 155" do
      result = unit(ikea: 145, addon: 10, weight: 10, d_ikea: 0)
      expect(result[:effective_price_p_pln]).to eq(BigDecimal("155"))
      expect(result[:pricing_mode]).to eq(:k)
      k = (BigDecimal("87") / BigDecimal("155")) - BigDecimal("0.187")
      expect(result[:markup_rate]).to be_within(1e-12).of(k)
    end
  end

  describe "D. P = 150" do
    it "uses cheap goods = 195" do
      result = unit(ikea: 150, weight: 10, d_ikea: 0)
      expect(result[:pricing_mode]).to eq(:cheap)
      expect(result[:goods_pln]).to eq(BigDecimal("195"))
    end
  end

  describe "E. P = 150.01" do
    it "jumps to k-formula without smoothing" do
      result = unit(ikea: 150.01, weight: 10, d_ikea: 0)
      expect(result[:pricing_mode]).to eq(:k)
      k = (BigDecimal("87") / BigDecimal("150.01")) - BigDecimal("0.187")
      goods = BigDecimal("150.01") * (1 + k)
      expect(result[:goods_pln]).to be_within(1e-8).of(goods)
      expect(result[:goods_pln].to_f).to be_within(0.0001).of(208.95813)
    end
  end

  describe "F. min markup" do
    it "does not go below 0.10 for high P" do
      result = unit(ikea: 10_000, weight: 10, d_ikea: 0)
      expect(result[:markup_rate]).to eq(BigDecimal("0.10"))
    end
  end

  describe "G-J. WC bands are non-progressive" do
    it "G. 20 kg uses 16.85" do
      expect(BelarusDeliveryService.calculate(20)).to eq(337.0)
    end

    it "H. 20.01 kg uses 12.81 for the whole weight" do
      expect(BelarusDeliveryService.calculate(20.01)).to eq((20.01 * 12.81).round(2))
    end

    it "I. 30 / 30.01 boundary" do
      expect(BelarusDeliveryService.calculate(30)).to eq((30 * 12.81).round(2))
      expect(BelarusDeliveryService.calculate(30.01)).to eq((30.01 * 10.69).round(2))
    end

    it "J. 40 / 40.01 boundary" do
      expect(BelarusDeliveryService.calculate(40)).to eq((40 * 10.69).round(2))
      expect(BelarusDeliveryService.calculate(40.01)).to eq((40.01 * 8.58).round(2))
    end
  end

  describe "K. quantity does not optimize WC" do
    it "multiplies unit WC instead of combining weight" do
      line = PriceCalculationService.line_breakdown_pln(
        unit_price_zl: 100,
        quantity: 2,
        weight_kg: 20,
        delivery_unit_pln: 0
      )
      expect(line[:wc_by_pln]).to eq(674.0)
      expect(line[:wc_by_pln]).not_to eq((40 * 10.69).round(2))
    end
  end

  describe "L. D_IKEA × quantity" do
    it "multiplies unit D_IKEA" do
      line = PriceCalculationService.line_breakdown_pln(
        unit_price_zl: 100,
        quantity: 3,
        weight_kg: 10,
        delivery_unit_pln: 50
      )
      expect(line[:delivery_pln]).to eq(150.0)
    end
  end

  describe "M-Q. customs C and weight" do
    it "M. C exactly 200 EUR has no customs" do
      result = unit(ikea: 984, weight: 10, d_ikea: 10)
      expect(result[:customs_cost_eur].to_f).to eq(200.0)
      expect(result[:customs_total_byn].to_f).to eq(0.0)
    end

    it "N. C slightly above 200 creates customs" do
      result = unit(ikea: 985, weight: 10, d_ikea: 10)
      expect(result[:customs_cost_eur].to_f).to be > 200.0
      expect(result[:customs_total_byn].to_f).to be > 0
      expect(result[:customs_fee_byn].to_f).to eq(10.0)
    end

    it "O. W = 31 has no weight duty" do
      result = unit(ikea: 100, weight: 31, d_ikea: 10)
      expect(result[:customs_total_byn].to_f).to eq(0.0)
    end

    it "P. W = 31.01 creates weight duty plus fee" do
      result = unit(ikea: 100, weight: 31.01, d_ikea: 10)
      expect(result[:customs_duty_byn].to_f).to be_within(0.01).of(((31.01 - 31) * 2 * 4).round(2))
      expect(result[:customs_fee_byn].to_f).to eq(10.0)
    end

    it "Q. both limits take max, not sum" do
      cost_duty = CustomsDutyService.calculate(300, 10, 4)
      weight_duty = CustomsDutyService.calculate(100, 50, 4)
      both = CustomsDutyService.calculate(300, 50, 4)
      expect(both[:duty_eur]).to eq([cost_duty[:duty_eur], weight_duty[:duty_eur]].max)
      expect(both[:fee_byn]).to eq(10.0)
    end
  end

  describe "R-T. card price" do
    it "R. ordinary card excludes customs" do
      result = unit(ikea: 100, weight: 10, d_ikea: 20)
      expect(result[:customs_included_in_card_price]).to eq(false)
      expect(result[:card_price_byn]).to eq(result[:base_price_byn])
    end

    it "S. expensive unit includes individual customs" do
      result = unit(ikea: 985, weight: 10, d_ikea: 20)
      expect(result[:customs_threshold_exceeded]).to eq(true)
      expect(result[:card_price_byn]).to eq(Pricing::Money.round2(result[:base_price_byn] + result[:customs_total_byn]))
    end

    it "T. heavy unit includes individual customs" do
      result = unit(ikea: 100, weight: 32, d_ikea: 20)
      expect(result[:customs_included_in_card_price]).to eq(true)
      expect(result[:card_price_byn].to_f).to be > result[:base_price_byn].to_f
    end
  end

  describe "cheap multiplier applies only to P" do
    it "does not multiply D_IKEA or WC by 1.3" do
      result = unit(ikea: 100, weight: 10, d_ikea: 20)
      wc = BigDecimal("10") * BigDecimal("16.85")
      expect(result[:goods_pln]).to eq(BigDecimal("130"))
      expect(result[:subtotal_pln]).to eq(BigDecimal("130") + 20 + wc)
      expect(result[:subtotal_pln]).not_to eq((BigDecimal("100") + 20 + wc) * BigDecimal("1.3"))
    end
  end

  describe "U-W. cart aggregate customs" do
    before { seed_rates! }

    it "U. two 150 EUR items create cart customs once" do
      # C = (IKEA / 1.23) * (1/4) = 150 => IKEA = 150 * 1.23 * 4 = 738
      a = priced_product(sku: "CART-A", price: 738, weight: 10, delivery_cost: 20)
      b = priced_product(sku: "CART-B", price: 738, weight: 10, delivery_cost: 20)
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: a.sku, quantity: 1)
      create(:cart_item, cart: cart, product_sku: b.sku, quantity: 1)

      card_a = PriceCalculationService.for_product(a, pln_rate: 1, eur_rate: 4, buffer: 1.05)
      card_b = PriceCalculationService.for_product(b, pln_rate: 1, eur_rate: 4, buffer: 1.05)
      expect(card_a[:customs_total_byn].to_f).to eq(0.0)
      expect(card_b[:customs_total_byn].to_f).to eq(0.0)

      pricing = CartPricingService.call(cart: cart)
      expect(pricing[:totals][:customs_duty_byn].to_f).to eq(60.0)
      expect(pricing[:totals][:customs_fee_byn].to_f).to eq(10.0)
      expect(pricing[:totals][:customs_total_byn].to_f).to eq(70.0)
    end

    it "V. two 20 kg items use cart weight 40 for customs but WC per 20 kg unit" do
      a = priced_product(sku: "W-A", price: 100, weight: 20, delivery_cost: 10)
      b = priced_product(sku: "W-B", price: 100, weight: 20, delivery_cost: 10)
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: a.sku, quantity: 1)
      create(:cart_item, cart: cart, product_sku: b.sku, quantity: 1)

      pricing = CartPricingService.call(cart: cart)
      expect(pricing[:totals][:total_weight_kg]).to eq(40.0)
      expect(pricing[:totals][:customs_total_byn].to_f).to be > 0
      wc_line = pricing[:items].sum { |row| row[:delivery_belarus_byn].to_f }
      expect(wc_line).to be_within(0.05).of((337.0 * 2 * 1.0 * 1.05).round(2))
    end

    it "W. customs fee is applied once for many items" do
      products = Array.new(3) { |i| priced_product(sku: "FEE-#{i}", price: 738, weight: 10, delivery_cost: 10) }
      user = create(:user)
      cart = create(:cart, user: user)
      products.each { |product| create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1) }

      pricing = CartPricingService.call(cart: cart)
      expect(pricing[:totals][:customs_fee_byn].to_f).to eq(10.0)
    end
  end

  describe "X-Y. missing data" do
    before { seed_rates! }

    it "X. missing weight makes pricing unavailable and blocks checkout" do
      product = create(:product, sku: "NO-W", price: 100, weight: nil, delivery_cost: 20, quantity: 5, full_attributes: {})
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      pricing = CartPricingService.call(cart: cart)
      expect(pricing[:items].first[:pricing_available]).to eq(false)
      expect(pricing[:items].first[:pricing_errors]).to include("missing_weight")
      expect(pricing[:meta][:can_checkout]).to eq(false)
    end

    it "Y. missing D_IKEA makes pricing unavailable and blocks checkout" do
      product = priced_product(sku: "NO-D", delivery_cost: nil)
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      pricing = CartPricingService.call(cart: cart)
      expect(pricing[:items].first[:pricing_available]).to eq(false)
      expect(pricing[:items].first[:pricing_errors]).to include("missing_ikea_delivery")
      expect(pricing[:meta][:can_checkout]).to eq(false)
    end
  end

  describe "Z. settings change formula without code changes" do
    it "reads pricing_cheap_multiplier from CalculatorSetting" do
      first = unit(ikea: 100, weight: 10, d_ikea: 0)
      CalculatorSetting.set("pricing_cheap_multiplier", 1.5)
      second = unit(ikea: 100, weight: 10, d_ikea: 0)
      expect(first[:goods_pln]).to eq(BigDecimal("130"))
      expect(second[:goods_pln]).to eq(BigDecimal("150"))
    end
  end

  describe "AA. initialize_defaults does not overwrite admin values" do
    it "keeps a manually changed setting" do
      CalculatorSetting.set("pricing_cheap_multiplier", 1.77)
      CalculatorSetting.initialize_defaults
      expect(CalculatorSetting.get("pricing_cheap_multiplier")).to eq(1.77)
    end
  end

  describe "AB. cache invalidation" do
    it "uses the new setting immediately after change" do
      seed_rates!
      product = priced_product(sku: "CACHE-1", price: 100, weight: 10, delivery_cost: 20)
      before = PriceCalculationService.for_product(product, pln_rate: 1, eur_rate: 4, buffer: 1.05)
      CalculatorSetting.set("pricing_cheap_multiplier", 2.0)
      after = PriceCalculationService.for_product(product, pln_rate: 1, eur_rate: 4, buffer: 1.05)
      expect(after[:goods_pln]).not_to eq(before[:goods_pln])
      expect(after[:goods_pln]).to eq(BigDecimal("200"))
    end
  end

  describe "AC. promo never reduces customs" do
    before { seed_rates! }

    it "applies discount only to base turnkey price" do
      product = priced_product(sku: "PROMO-C", price: 985, weight: 10, delivery_cost: 20)
      promo = PromoCode.create!(code: "HALF", discount_type: :percent, discount_value: 50, active: true)
      user = create(:user)
      cart = create(:cart, user: user, promo_code: promo)
      create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

      pricing = CartPricingService.call(cart: cart)
      customs = pricing[:totals][:customs_total_byn].to_f
      expect(customs).to be > 0
      expect(pricing[:totals][:discount_total_byn].to_f).to be_within(0.02).of((pricing[:items].first[:unit_price_byn_before_discount] * 0.5).round(2))
      expected_total = (
        pricing[:totals][:items_total_byn].to_f -
          pricing[:totals][:discount_total_byn].to_f +
          customs
      ).round(2)
      expect(pricing[:totals][:total_byn].to_f).to eq(expected_total)
    end
  end

  describe "AD. checkout/payment includes cart customs once" do
    before { seed_rates! }

    it "adds customs exactly once to payable total" do
      a = priced_product(sku: "PAY-A", price: 738, weight: 10, delivery_cost: 20)
      b = priced_product(sku: "PAY-B", price: 738, weight: 10, delivery_cost: 20)
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: a.sku, quantity: 1)
      create(:cart_item, cart: cart, product_sku: b.sku, quantity: 1)
      pricing = CartPricingService.call(cart: cart)

      total = CheckoutService.send(
        :checkout_total_amount,
        pricing: pricing,
        prices: { total_delivery_price_byn: 12.43 }
      )
      display = CartDisplayTotalsService.for_summary(pricing[:totals])
      expect(display[:customs_total_byn].to_f).to eq(70.0)
      expect(total).to eq(
        (display[:items_total_byn].to_f - display[:discount_total_byn].to_f + 70.0 + 12.43).round(2)
      )
    end
  end

  describe "nil is not coerced to zero" do
    it "returns nil from BelarusDeliveryService.quote" do
      expect(BelarusDeliveryService.quote(nil)).to be_nil
    end

    it "does not price a unit with nil D_IKEA as free delivery" do
      result = unit(ikea: 100, weight: 10, d_ikea: nil)
      expect(result[:pricing_available]).to eq(false)
      expect(result[:pricing_errors]).to include("missing_ikea_delivery")
      expect(result[:card_price_byn]).to be_nil
    end
  end
end
