# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::ProductsXlsxExportService do
  let(:pln_rate) { 1.0 }
  let(:eur_rate) { 4.0 }
  let(:buffer) { 1.05 }

  before do
    CalculatorSetting.initialize_defaults
    allow(ExchangeRate).to receive(:fetch_or_create).with("PLN").and_return(double(rate_per_unit: pln_rate))
    allow(ExchangeRate).to receive(:fetch_or_create).with("EUR").and_return(double(rate_per_unit: eur_rate))
  end

  def product_for(price:, weight:, delivery_cost:, addon: 0)
    create(
      :product,
      price: price,
      weight: weight,
      delivery_cost: delivery_cost,
      price_addon_pln: addon,
      full_attributes: {
        "dimensions_map" => {
          "packaging" => {
            "details" => [
              { "weight" => "#{weight} кг", "count" => 1, "width" => "20 см", "height" => "30 см", "length" => "40 см" }
            ]
          }
        }
      }
    )
  end

  def row_for(product)
    described_class.send(
      :build_pricing_row,
      product: product,
      pln_rate: pln_rate,
      eur_rate: eur_rate,
      buffer: buffer,
      rate_with_buffer: (pln_rate * buffer).round(4),
      vgh_limits: { max_weight_kg: 50, max_volume_m3: 1, max_dimension_cm: 200 }
    )
  end

  it "uses the shared pricing service for the service/card price" do
    product = product_for(price: 100, weight: 10, delivery_cost: 20)
    unit = PriceCalculationService.for_product(product, pln_rate: pln_rate, eur_rate: eur_rate, buffer: buffer)
    row = row_for(product)

    expect(row[:price_byn]).to eq(Pricing::Money.to_f_round2(unit[:card_price_byn]))
    expect(row[:goods_pln]).to eq(130.0)
    expect(row[:delivery_pln]).to eq(20.0)
    expect(row[:wc_by_pln]).to eq(168.5)
    expect(row[:customs_byn]).to eq(0.0)
  end

  it "does not apply the cheap multiplier to D_IKEA or WC" do
    product = product_for(price: 100, weight: 10, delivery_cost: 50)
    row = row_for(product)
    expect(row[:goods_pln]).to eq(130.0)
    expect(row[:delivery_pln]).to eq(50.0)
    expect(row[:wc_by_pln]).to eq(168.5)
  end

  it "keeps customs as a separate column even when it is already in the card price" do
    product = product_for(price: 1200, weight: 10, delivery_cost: 20)
    unit = PriceCalculationService.for_product(product, pln_rate: pln_rate, eur_rate: eur_rate, buffer: buffer)
    row = row_for(product)

    expect(unit[:customs_included_in_card_price]).to eq(true)
    expect(row[:price_byn]).to eq(Pricing::Money.to_f_round2(unit[:card_price_byn]))
    expect(row[:customs_byn]).to eq(Pricing::Money.to_f_round2(unit[:customs_total_byn]))
    expect(row[:price_byn]).to be > row[:customs_byn]
  end
end
