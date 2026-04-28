require "rails_helper"

RSpec.describe DeliveryEtaService do
  describe ".call" do
    before do
      allow(CalculatorSetting).to receive(:get).with("delivery_days_default").and_return(14)
      allow(CalculatorSetting).to receive(:get).with("europost_storage_days").and_return(14)
      allow(CalculatorSetting).to receive(:get).with("default_delivery_days").and_return(30)
    end

    it "returns regular weekday delivery date" do
      result = described_class.call(order_date: Date.new(2026, 4, 13), with_storage: false) # Monday + 14 => Monday

      expect(result[:delivery_date]).to eq(Date.new(2026, 4, 27))
      expect(result[:storage_until]).to be_nil
    end

    it "moves saturday delivery to monday" do
      result = described_class.call(order_date: Date.new(2026, 4, 18), with_storage: false) # Saturday + 14 => Saturday

      expect(result[:delivery_date]).to eq(Date.new(2026, 5, 4))
      expect(result[:delivery_date].wday).to eq(1)
    end

    it "moves sunday delivery to monday" do
      result = described_class.call(order_date: Date.new(2026, 4, 19), with_storage: false) # Sunday + 14 => Sunday

      expect(result[:delivery_date]).to eq(Date.new(2026, 5, 4))
      expect(result[:delivery_date].wday).to eq(1)
    end

    it "returns storage_until when with_storage is true" do
      result = described_class.call(order_date: Date.new(2026, 4, 13), with_storage: true)

      expect(result[:delivery_date]).to eq(Date.new(2026, 4, 27))
      expect(result[:storage_until]).to eq(Date.new(2026, 5, 11))
    end

    it "returns nil storage_until when with_storage is false" do
      result = described_class.call(order_date: Date.new(2026, 4, 13), with_storage: false)

      expect(result[:delivery_date]).to eq(Date.new(2026, 4, 27))
      expect(result[:storage_until]).to be_nil
    end
  end
end
