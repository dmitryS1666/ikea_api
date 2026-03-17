require 'rails_helper'

RSpec.describe BelarusDeliveryService do
  before do
    # Создаем настройки по умолчанию (новая логика)
    CalculatorSetting.initialize_defaults
  end
  
  describe '.calculate' do
    it 'возвращает 16.85 PLN за кг для веса 0-20 кг' do
      expect(described_class.calculate(10.0)).to eq(168.5) # 10 * 16.85
      expect(described_class.calculate(20.0)).to eq(337.0) # 20 * 16.85
    end
    
    it 'возвращает 12.81 PLN за кг для веса 20-30 кг' do
      expect(described_class.calculate(25.0)).to eq(320.25) # 25 * 12.81
      expect(described_class.calculate(30.0)).to eq(384.30) # 30 * 12.81
    end
    
    it 'возвращает 10.69 PLN за кг для веса 30-40 кг' do
      expect(described_class.calculate(35.0)).to eq(374.15) # 35 * 10.69
      expect(described_class.calculate(40.0)).to eq(427.60) # 40 * 10.69
    end
    
    it 'возвращает 8.58 PLN за кг для веса 40-1000 кг' do
      expect(described_class.calculate(50.0)).to eq(429.0) # 50 * 8.58
      expect(described_class.calculate(100.0)).to eq(858.0) # 100 * 8.58
    end
    
    it 'округляет результат до 2 знаков после запятой' do
      result = described_class.calculate(25.0)
      expect(result.to_s.split('.').last.length).to be <= 2
    end
  end
  
  describe '.delivery_rates' do
    it 'возвращает тарифы из настроек' do
      rates = described_class.delivery_rates
      expect(rates).to be_an(Array)
      expect(rates.length).to be > 0
      expect(rates[0][1]).to eq(16.85)
    end
  end
end
