require 'rails_helper'

RSpec.describe PriceCalculationService do
  let(:date) { Date.today }
  let(:pln_rate) { 0.85 } # 1 PLN = 0.85 BYN
  let(:eur_rate) { 3.5 }  # 1 EUR = 3.5 BYN

  before do
    CalculatorSetting.initialize_defaults

    ExchangeRate.create!(
      date: date,
      currency_code: 'PLN',
      rate: pln_rate,
      official_rate: pln_rate,
      scale: 1
    )
    
    ExchangeRate.create!(
      date: date,
      currency_code: 'EUR',
      rate: eur_rate,
      official_rate: eur_rate,
      scale: 1
    )

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('PRICE_CHEAP_THRESHOLD_PLN', anything).and_return('150')
  end

  describe '.pricing_mode_for' do
    it 'выбирает cheap на пороге' do
      expect(described_class.pricing_mode_for(150.0)).to eq(:cheap)
    end

    it 'выбирает k выше порога' do
      expect(described_class.pricing_mode_for(150.01)).to eq(:k)
    end
  end

  describe '.line_total_pln' do
    it 'считает cheap-режим как (price + delivery + wc) * 1.3' do
      # wc = 10 * 16.85 = 168.5
      total = described_class.line_total_pln(
        unit_price_zl: 100.0,
        quantity: 1,
        weight_kg: 10.0,
        delivery_unit_pln: 20.0
      )
      expect(total).to eq(374.05) # (100 + 20 + 168.5) * 1.3
    end

    it 'считает k-режим по формуле K только на цену IKEA' do
      total = described_class.line_total_pln(
        unit_price_zl: 500.0,
        quantity: 1,
        weight_kg: 15.0,
        delivery_unit_pln: 50.0
      )
      expect(total).to eq(852.75) # 500*1.10 + 50 + 252.75
    end
  end

  describe '.product_price_byn' do
    it 'корректно считает BYN и округляет до 2 знаков' do
      price_byn = described_class.product_price_byn(500.0, weight_kg: 15.0, delivery_pln: 50.0, pln_rate: pln_rate, buffer: 1.05)
      expect(price_byn).to eq((852.75 * pln_rate * 1.05).round(2))
    end

    it 'не добавляет весовую часть при нулевом или отсутствующем весе' do
      with_zero_weight = described_class.product_price_byn(100.0, weight_kg: 0, delivery_pln: 20.0, pln_rate: pln_rate, buffer: 1.05)
      without_weight = described_class.product_price_byn(100.0, delivery_pln: 20.0, pln_rate: pln_rate, buffer: 1.05)
      expect(with_zero_weight).to eq(without_weight)
    end
  end

  describe '.calculate' do
    it 'возвращает режим и итоговую сумму по новой формуле' do
      result = described_class.calculate(500.0, 15.0, delivery_pln: 50.0, date: date)

      expect(result[:pricing_mode]).to eq('k')
      expect(result[:markup_k]).to eq(0.10)
      expect(result[:total_pln]).to eq(852.75)
      expect(result[:total_price_byn]).to eq((852.75 * pln_rate * 1.05).round(2))
    end
  end
end
