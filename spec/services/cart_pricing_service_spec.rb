require "rails_helper"

RSpec.describe CartPricingService do
  let(:date) { Date.today }

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

  it "применяет процентный промокод к финальной BYN цене с учетом всех наценок" do
    user = create(:user)
    product = create(:product, sku: "SKU-PROMO-1", price: 500.0, weight: 15.0, delivery_cost: 50.0, quantity: 5)
    promo = PromoCode.create!(code: "SALE10", discount_type: :percent, discount_value: 10, active: true)
    cart = create(:cart, user: user, promo_code: promo)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first

    expect(item[:unit_price_byn_before_discount]).to be_within(0.01).of(535.5) # витрина: товар + доставка PL, без РБ
    expect(item[:unit_discount_byn]).to eq(53.55)
    expect(item[:line_total_byn]).to be_within(0.02).of(481.95)
    expect(item[:line_total_byn_checkout]).to eq(707.54)
    expect(item[:unit_price_byn_checkout]).to eq(707.54)
    expect(pricing[:totals][:discount_total_byn]).to eq(53.55)
    expect(pricing[:totals][:total_byn]).to eq(707.54)
  end

  it "ограничивает fixed_byn скидку ценой позиции после всех наценок" do
    user = create(:user)
    product = create(:product, sku: "SKU-PROMO-2", price: 100.0, weight: 0.0, delivery_cost: 0.0, quantity: 5)
    promo = PromoCode.create!(code: "BIGFIX", discount_type: :fixed_byn, discount_value: 9999, active: true)
    cart = create(:cart, user: user, promo_code: promo)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first

    expect(item[:line_total_byn]).to eq(0.0)
    expect(item[:unit_discount_byn]).to eq(item[:unit_price_byn_before_discount])
  end

  it "включает доставку по Беларуси как сумму весов всех упаковок" do
    user = create(:user)
    product = create(
      :product,
      sku: "SKU-BULKY-1",
      price: 500.0,
      weight: nil,
      delivery_cost: 50.0,
      quantity: 5,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "15 кг", "count" => 1, "width" => "80 см", "height" => "40 см", "length" => "150 см" },
              { "weight" => "10 кг", "count" => 1, "width" => "60 см", "height" => "30 см", "length" => "120 см" }
            ]
          }
        }
      }
    )
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: Cart.find(cart.id))
    wc_by_byn = (BelarusDeliveryService.calculate(25.0) * 0.85 * 1.05).round(2)

    expect(pricing[:totals][:total_weight_kg]).to eq(25.0)
    expect(pricing[:totals][:delivery_total_byn]).to be >= wc_by_byn
    expect(pricing[:totals][:delivery_to_belarus_byn]).to be >= wc_by_byn
    # В публичном summary delivery_total_byn — это видимая строка
    # "Доставка в Беларусь". Доставка по Польше уже включена в
    # subtotal_new_byn / items_total_byn как часть стоимости товаров.
    expect(pricing[:totals][:delivery_poland_byn]).to be > 0
    expect(pricing[:totals][:delivery_total_byn]).to eq(pricing[:totals][:delivery_to_belarus_byn])
  end

  it "разрешает checkout по витринной subtotal_new_byn, а не по сырой цене IKEA в PLN" do
    user = create(:user)
    first = create(:product, sku: "SKU-MIN-1", price: 70.0, weight: 1.0, delivery_cost: 5.0, quantity: 10)
    second = create(:product, sku: "SKU-MIN-2", price: 70.0, weight: 1.0, delivery_cost: 5.0, quantity: 10)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: first.sku, quantity: 1)
    create(:cart_item, cart: cart, product_sku: second.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    raw_goods_byn = ((first.price + second.price) * 0.85 * 1.05).round(2)
    storefront_lines_byn = pricing[:items].sum { |item| item[:line_total_byn].to_f }

    expect(raw_goods_byn).to be < 150.0
    expect(pricing[:totals][:subtotal_new_byn]).to be_within(0.03).of(storefront_lines_byn)
    expect(pricing[:totals][:subtotal_new_byn]).to be >= 150.0
    expect(pricing[:meta][:can_checkout]).to be(true)
  end

  it "считает unit_price_byn без доставки в Беларусь, но сохраняет полную сумму для checkout" do
    user = create(:user)
    product = create(
      :product,
      sku: "SKU-STORE-1",
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

    pricing = described_class.call(cart: Cart.find(cart.id))
    item = pricing[:items].first

    expect(item[:line_total_byn]).to be < item[:line_total_byn_checkout]
    expect(item[:line_total_byn] + pricing[:totals][:delivery_to_belarus_byn]).to be_within(0.03).of(item[:line_total_byn_checkout])
    expect(pricing[:totals][:total_byn]).to eq(item[:line_total_byn_checkout])
  end

  it "строит checkout total из тех же округленных компонентов, которые видит пользователь" do
    user = create(:user)
    product = create(:product, sku: "SKU-ROUND-1", price: 500.0, weight: 17.3, delivery_cost: 0.0, quantity: 5)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    allow(PriceCalculationService).to receive(:line_breakdown_pln).and_return(
      mode: :k,
      markup_k: 0.1
    )
    allow(PriceCalculationService).to receive(:line_byn_components).and_return(
      goods_byn: 197.13,
      delivery_poland_byn: 0.0,
      delivery_belarus_byn: 41.12,
      total_byn: 238.26
    )

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first

    expect(item[:line_total_byn]).to eq(197.13)
    expect(item[:line_total_byn_checkout]).to eq(238.25)
    expect(pricing[:totals][:subtotal_new_byn]).to eq(197.13)
    expect(pricing[:totals][:delivery_to_belarus_byn]).to eq(41.12)
    expect(pricing[:totals][:total_byn]).to eq(238.25)
  end

  it "uses parcel packing weight for totals and matches delivery options VGH" do
    user = create(:user)
    product = create(
      :product,
      sku: "SKU-WEIGHT-10X",
      price: 100.0,
      weight: 1.0,
      delivery_cost: 5.0,
      quantity: 10,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "13.36 кг", "count" => 1, "width" => "80 см", "height" => "40 см", "length" => "150 см" },
              { "weight" => "13.36 кг", "count" => 1, "width" => "60 см", "height" => "30 см", "length" => "120 см" }
            ]
          }
        }
      }
    )
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 10)

    pricing = described_class.call(cart: cart)
    delivery_options = DeliveryOptionsService.call(cart)

    expect(pricing[:totals][:total_weight_kg]).to eq(delivery_options.dig(:cart_vgh, :weight_kg))
    expect(pricing[:totals][:total_weight_kg]).to be_within(0.1).of(267.2)
    expect(pricing[:totals][:subtotal_new_byn]).to eq(pricing[:items].sum { |item| item[:line_total_byn].to_f })
  end
end
