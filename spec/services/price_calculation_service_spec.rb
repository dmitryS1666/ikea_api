require 'rails_helper'

RSpec.describe PriceCalculationService do
  let(:date) { Date.today }
  let(:pln_rate) { 0.85 } # 1 PLN = 0.85 BYN
  let(:eur_rate) { 3.5 }  # 1 EUR = 3.5 BYN
  
  before do
    # Создаем настройки по умолчанию (новая логика)
    CalculatorSetting.initialize_defaults
    
    # Создаем тестовые курсы валют
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
  end
  
  describe '.compute_k' do
    it 'возвращает 0.10 для дорогого товара (например, 1000 PLN)' do
      # 87 / 1000 - 0.187 = 0.087 - 0.187 = -0.1 (но не меньше 0.10)
      expect(described_class.compute_k(1000.0)).to eq(0.10)
    end
    
    it 'возвращает повышенную наценку для дешевого товара (например, 200 PLN)' do
      # 87 / 200 - 0.187 = 0.435 - 0.187 = 0.248
      expect(described_class.compute_k(200.0).round(3)).to eq(0.248)
    end

    it 'возвращает 0.10 для товара из примера (500 PLN)' do
      # 87 / 500 - 0.187 = 0.174 - 0.187 = -0.013 -> 0.10
      expect(described_class.compute_k(500.0)).to eq(0.10)
    end
  end

  describe '.calculate' do
    context 'с параметрами из регламента (фиксированная доставка 50 PLN)' do
      let(:product_price_zl) { 500.0 }
      let(:weight_kg) { 15.0 }
      
      it 'возвращает расчет как в примере' do
        result = described_class.calculate(
          product_price_zl,
          weight_kg,
          use_gls_pickup: false,
          delivery_pln: 50.0,
          date: date
        )
        
        # K: 10% → 500 * 1.10 = 550 PLN
        # Доставка: 50 PLN
        # WC_BY: 15 * 16.85 = 252.75 PLN
        # Итого PLN: 852.75
        
        expect(result[:markup_k]).to eq(0.10)
        expect(result[:total_pln]).to eq(852.75)
        
        expected_byn = (852.75 * pln_rate * 1.05).round(2)
        expect(result[:total_price_byn]).to eq(expected_byn)
      end
    end

    context 'без явной доставки — тариф по Польше (15 кг → 79 PLN)' do
      let(:product_price_zl) { 500.0 }
      let(:weight_kg) { 15.0 }

      it 'подставляет poland_delivery_rates' do
        result = described_class.calculate(product_price_zl, weight_kg, use_gls_pickup: false, date: date)
        expect(result[:delivery_pln]).to eq(79.0)
        expect(result[:total_pln]).to eq(881.75)
      end
    end
    
    context 'с GLS пунктом отбора' do
      let(:product_price_zl) { 50.0 }
      let(:weight_kg) { 25.0 }
      
      it 'доставка по Польше бесплатна для веса до 30 кг' do
        result = described_class.calculate(product_price_zl, weight_kg, use_gls_pickup: true, date: date)
        expect(result[:poland_delivery_zl]).to eq(0.0)
      end
    end
  end
end
