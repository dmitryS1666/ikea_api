# frozen_string_literal: true

require "rails_helper"

RSpec.describe CurrencyRateService do
  describe ".fetch_rates" do
    let(:api_body) do
      {
        result: "success",
        time_last_update_utc: "Sat, 12 Sep 2026 00:02:31 +0000",
        base_code: "PLN",
        rates: {
          PLN: 1,
          USD: 0.268572,
          EUR: 0.231375,
          BYN: 0.815084
        }
      }
    end

    it "inverts USD/EUR to PLN and derives BYN from the same table" do
      stub_request(:get, described_class::ER_API_URL)
        .to_return(status: 200, body: api_body.to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.fetch_rates

      expect(result[:effective_date]).to eq("2026-09-12")
      expect(result[:rates]).to contain_exactly(
        hash_including(code: "USD", currency: "dolar amerykański", mid: 3.7234),
        hash_including(code: "EUR", currency: "euro", mid: 4.322)
      )
      expect(result[:byn_rates]["PLN"]).to be_within(0.000001).of(0.815084)
      expect(result[:byn_rates]["USD"]).to be_within(0.0001).of(0.815084 / 0.268572)
      expect(result[:byn_rates]["EUR"]).to be_within(0.0001).of(0.815084 / 0.231375)
    end

    it "raises when a required currency is missing" do
      stub_request(:get, described_class::ER_API_URL)
        .to_return(
          status: 200,
          body: api_body.merge(rates: { USD: 0.26, EUR: 0.23 }).to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { described_class.fetch_rates }.to raise_error(StandardError, /missing rates: BYN/)
    end
  end

  describe ".format_rates_for_telegram" do
    let(:rates) do
      {
        effective_date: "2026-09-12",
        rates: [
          { currency: "dolar amerykański", code: "USD", mid: 3.7234 },
          { currency: "euro", code: "EUR", mid: 4.322 }
        ],
        byn_rates: {
          "PLN" => 0.815084,
          "USD" => 3.0356,
          "EUR" => 3.5228
        }
      }
    end

    it "adds BYN rate for each currency from the same payload" do
      expect(ExchangeRate).not_to receive(:fetch_or_create)

      message = described_class.format_rates_for_telegram(rates)

      expect(message).to include("💱 <b>Актуальные курсы валют (ExchangeRate-API)</b>")
      expect(message).to include("🇵🇱 <b>złoty polski</b>")
      expect(message).to include("Курс: 1.0 PLN (базовая валюта)")
      expect(message).to include("Курс: 0.8151 BYN")

      expect(message).to include("🇺🇸 <b>dolar amerykański</b>")
      expect(message).to include("Курс: 3.7234 PLN")
      expect(message).to include("Курс: 3.0356 BYN")

      expect(message).to include("🇪🇺 <b>euro</b>")
      expect(message).to include("Курс: 4.322 PLN")
      expect(message).to include("Курс: 3.5228 BYN")
    end

    it "shows н/д when a BYN rate is missing" do
      rates[:byn_rates].delete("USD")

      message = described_class.format_rates_for_telegram(rates)

      expect(message).to include("Курс: 3.7234 PLN")
      expect(message).to include("Курс: н/д")
    end
  end
end
