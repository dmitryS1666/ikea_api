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

    expect(item[:unit_price_byn_before_discount]).to eq(761.08) # 852.75 PLN * 0.85 * 1.05
    expect(item[:unit_discount_byn]).to eq(76.11)
    expect(item[:line_total_byn]).to eq(684.97)
    expect(pricing[:totals][:discount_total_byn]).to eq(76.11)
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
  end
end
