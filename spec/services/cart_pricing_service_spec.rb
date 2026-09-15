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
  end

  def turnkey_product(sku:, price:, weight:, delivery_cost:)
    create(
      :product,
      sku: sku,
      price: price,
      weight: weight,
      delivery_cost: delivery_cost,
      quantity: 10,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "#{weight} кг", "count" => 1, "width" => "80 см", "height" => "40 см", "length" => "150 см" }
            ]
          }
        }
      }
    )
  end

  it "применяет процентный промокод только к turnkey base, не к таможне" do
    user = create(:user)
    product = turnkey_product(sku: "SKU-PROMO-1", price: 500.0, weight: 15.0, delivery_cost: 50.0)
    promo = PromoCode.create!(code: "SALE10", discount_type: :percent, discount_value: 10, active: true)
    cart = create(:cart, user: user, promo_code: promo)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first
    unit = PriceCalculationService.for_product(product, pln_rate: 0.85, eur_rate: 3.5, buffer: 1.05)

    expect(item[:unit_price_byn_before_discount]).to eq(Pricing::Money.to_f_round2(unit[:base_price_byn]))
    expect(item[:unit_discount_byn]).to eq((item[:unit_price_byn_before_discount] * 0.1).round(2))
    expect(pricing[:totals][:total_byn]).to eq(
      (
        pricing[:totals][:items_total_byn].to_f -
          pricing[:totals][:discount_total_byn].to_f +
          pricing[:totals][:customs_total_byn].to_f
      ).round(2)
    )
  end

  it "ограничивает fixed_byn скидку базой позиции и не трогает customs" do
    user = create(:user)
    product = turnkey_product(sku: "SKU-PROMO-2", price: 100.0, weight: 5.0, delivery_cost: 10.0)
    promo = PromoCode.create!(code: "BIGFIX", discount_type: :fixed_byn, discount_value: 9999, active: true)
    cart = create(:cart, user: user, promo_code: promo)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first

    expect(item[:line_total_byn]).to eq(0.0)
    expect(item[:unit_discount_byn]).to eq(item[:unit_price_byn_before_discount])
    expect(pricing[:totals][:total_byn]).to eq(pricing[:totals][:customs_total_byn].to_f)
  end

  it "считает WC по весу одной единицы и умножает на quantity" do
    user = create(:user)
    product = turnkey_product(sku: "SKU-BULKY-1", price: 500.0, weight: 25.0, delivery_cost: 50.0)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: Cart.find(cart.id))
    wc_by_byn = (BelarusDeliveryService.calculate(25.0) * 0.85 * 1.05).round(2)

    expect(pricing[:totals][:total_weight_kg]).to eq(25.0)
    expect(pricing[:totals][:delivery_to_belarus_byn]).to be_within(0.02).of(wc_by_byn)
    expect(pricing[:totals][:delivery_total_byn]).to eq(0.0)
    expect(pricing[:totals][:delivery_poland_byn]).to be > 0
    expect(pricing[:totals][:items_total_byn]).to be > pricing[:totals][:delivery_to_belarus_byn]
  end

  it "разрешает checkout по turnkey items_total_byn" do
    user = create(:user)
    first = turnkey_product(sku: "SKU-MIN-1", price: 70.0, weight: 1.0, delivery_cost: 5.0)
    second = turnkey_product(sku: "SKU-MIN-2", price: 70.0, weight: 1.0, delivery_cost: 5.0)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: first.sku, quantity: 1)
    create(:cart_item, cart: cart, product_sku: second.sku, quantity: 1)

    pricing = described_class.call(cart: cart)
    expect(pricing[:totals][:subtotal_new_byn]).to be >= 150.0
    expect(pricing[:meta][:can_checkout]).to be(true)
  end

  it "хранит turnkey цену в line_total и не отделяет WC во второй раз" do
    user = create(:user)
    product = turnkey_product(sku: "SKU-STORE-1", price: 500.0, weight: 15.0, delivery_cost: 50.0)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)

    pricing = described_class.call(cart: Cart.find(cart.id))
    item = pricing[:items].first

    expect(item[:line_total_byn]).to eq(item[:line_total_byn_checkout])
    expect(pricing[:totals][:total_byn]).to eq(
      (item[:line_total_byn] + pricing[:totals][:customs_total_byn].to_f).round(2)
    )
  end

  it "uses packaging weight for customs cart weight and matches delivery options VGH" do
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
    expect(pricing[:totals][:subtotal_new_byn]).to eq(pricing[:items].sum { |item| item[:unit_price_byn_before_discount].to_f * item[:quantity] })
  end

  it "keeps unit_price × quantity equal to line_total for multi-qty rows" do
    user = create(:user)
    product = turnkey_product(sku: "SKU-UNIT-LINE", price: 248.0, weight: 26.72, delivery_cost: 5.0)
    cart = create(:cart, user: user)
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 10)

    pricing = described_class.call(cart: cart)
    item = pricing[:items].first

    expect((item[:unit_price_byn] * item[:quantity]).round(2)).to eq(item[:line_total_byn])
  end
end
