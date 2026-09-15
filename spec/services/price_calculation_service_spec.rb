require "rails_helper"

RSpec.describe PriceCalculationService do
  let(:date) { Date.today }
  let(:pln_rate) { 0.85 }
  let(:eur_rate) { 3.5 }

  before do
    CalculatorSetting.initialize_defaults

    ExchangeRate.create!(
      date: date,
      currency_code: "PLN",
      rate: pln_rate,
      official_rate: pln_rate,
      scale: 1
    )

    ExchangeRate.create!(
      date: date,
      currency_code: "EUR",
      rate: eur_rate,
      official_rate: eur_rate,
      scale: 1
    )
  end

  describe ".pricing_mode_for" do
    it "выбирает cheap на пороге" do
      expect(described_class.pricing_mode_for(150.0)).to eq(:cheap)
    end

    it "выбирает k выше порога" do
      expect(described_class.pricing_mode_for(150.01)).to eq(:k)
    end
  end

  describe ".line_total_pln" do
    it "считает cheap-режим как goods=P×1.3, затем + D_IKEA + WC" do
      total = described_class.line_total_pln(
        unit_price_zl: 100.0,
        quantity: 1,
        weight_kg: 10.0,
        delivery_unit_pln: 20.0
      )
      expect(total).to eq(318.5) # 130 + 20 + 168.5
    end

    it "считает k-режим по формуле K только на P" do
      total = described_class.line_total_pln(
        unit_price_zl: 500.0,
        quantity: 1,
        weight_kg: 15.0,
        delivery_unit_pln: 50.0
      )
      expect(total).to eq(852.75) # 500*1.10 + 50 + 252.75
    end
  end

  describe ".product_price_byn" do
    it "включает WC в карточную цену и округляет до 2 знаков" do
      price_byn = described_class.product_price_byn(500.0, weight_kg: 15.0, delivery_pln: 50.0, pln_rate: pln_rate, buffer: 1.05, eur_rate: eur_rate)
      expect(price_byn).to eq((852.75 * pln_rate * 1.05).round(2))
    end

    it "не считает цену при отсутствии веса" do
      with_zero_weight = described_class.product_price_byn(100.0, weight_kg: 0, delivery_pln: 20.0, pln_rate: pln_rate, buffer: 1.05, eur_rate: eur_rate)
      without_weight = described_class.product_price_byn(100.0, delivery_pln: 20.0, pln_rate: pln_rate, buffer: 1.05, eur_rate: eur_rate)
      expect(with_zero_weight).to be_nil
      expect(without_weight).to be_nil
    end
  end

  describe ".product_storefront_price_byn" do
    it "совпадает с карточной ценой, включая WC" do
      total = described_class.product_price_byn(500.0, weight_kg: 15.0, delivery_pln: 50.0, pln_rate: pln_rate, buffer: 1.05, eur_rate: eur_rate)
      storefront = described_class.product_storefront_price_byn(500.0, weight_kg: 15.0, delivery_pln: 50.0, pln_rate: pln_rate, buffer: 1.05, eur_rate: eur_rate)
      components = described_class.line_byn_components(
        unit_price_zl: 500.0,
        weight_kg: 15.0,
        delivery_unit_pln: 50.0,
        pln_rate: pln_rate,
        buffer: 1.05,
        eur_rate: eur_rate
      )

      expect(storefront).to eq(total)
      expect(storefront).to eq(components[:total_byn])
    end
  end

  describe ".calculate" do
    it "возвращает режим и итоговую сумму по новой формуле" do
      result = described_class.calculate(500.0, 15.0, delivery_pln: 50.0, date: date)

      expect(result[:pricing_mode]).to eq("k")
      expect(result[:markup_k]).to eq(0.10)
      expect(result[:total_pln]).to eq(852.75)
      expect(result[:total_price_byn]).to eq((852.75 * pln_rate * 1.05).round(2))
    end
  end
end
