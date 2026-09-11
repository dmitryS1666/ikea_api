# frozen_string_literal: true

require "rails_helper"

RSpec.describe CurrencyRateService do
  describe ".format_rates_for_telegram" do
    let(:date) { Date.new(2026, 9, 10) }
    let(:rates) do
      {
        effective_date: "2026-09-10",
        rates: [
          { currency: "dolar amerykański", code: "USD", mid: 3.7103 },
          { currency: "euro", code: "EUR", mid: 4.318 }
        ]
      }
    end

    before do
      allow(ExchangeRate).to receive(:fetch_or_create).with("PLN", date)
        .and_return(instance_double(ExchangeRate, rate_per_unit: 0.76115))
      allow(ExchangeRate).to receive(:fetch_or_create).with("USD", date)
        .and_return(instance_double(ExchangeRate, rate_per_unit: 2.9521))
      allow(ExchangeRate).to receive(:fetch_or_create).with("EUR", date)
        .and_return(instance_double(ExchangeRate, rate_per_unit: 3.2849))
    end

    it "adds NBRB BYN rate for each currency" do
      message = described_class.format_rates_for_telegram(rates)

      expect(message).to include("🇵🇱 <b>złoty polski</b>")
      expect(message).to include("Курс: 1.0 PLN (базовая валюта)")
      expect(message).to include("Курс: 0.7612 BYN")

      expect(message).to include("🇺🇸 <b>dolar amerykański</b>")
      expect(message).to include("Курс: 3.7103 PLN")
      expect(message).to include("Курс: 2.9521 BYN")

      expect(message).to include("🇪🇺 <b>euro</b>")
      expect(message).to include("Курс: 4.318 PLN")
      expect(message).to include("Курс: 3.2849 BYN")
    end

    it "shows н/д when a BYN rate is missing" do
      allow(ExchangeRate).to receive(:fetch_or_create).with("USD", date).and_return(nil)

      message = described_class.format_rates_for_telegram(rates)

      expect(message).to include("Курс: 3.7103 PLN")
      expect(message).to include("Курс: н/д")
    end

    it "keeps NBP rates if NBRB lookup fails" do
      allow(ExchangeRate).to receive(:fetch_or_create).and_raise(StandardError, "NBRB down")

      message = described_class.format_rates_for_telegram(rates)

      expect(message).to include("Курс: 1.0 PLN (базовая валюта)")
      expect(message).to include("Курс: 3.7103 PLN")
      expect(message).to include("Курс: н/д")
    end
  end
end
