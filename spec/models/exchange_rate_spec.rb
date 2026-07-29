require "rails_helper"

RSpec.describe ExchangeRate, type: :model do
  let(:today) { Date.current }
  let(:yesterday) { today - 1.day }

  before do
    described_class::API_FAILURES.clear
    allow(Rails.cache).to receive(:read).and_return(nil)
    allow(Rails.cache).to receive(:write)
    allow(Rails.cache).to receive(:delete)
  end

  def create_rate(code:, date:, rate:, scale: 1)
    described_class.create!(
      currency_code: code,
      date: date,
      rate: rate,
      official_rate: rate,
      scale: scale
    )
  end

  describe ".fetch_or_create" do
    it "returns existing rate for the date without calling NBRB" do
      existing = create_rate(code: "PLN", date: today, rate: 7.5, scale: 10)
      expect(NbrbApiService).not_to receive(:get_rate)

      expect(described_class.fetch_or_create("PLN", today)).to eq(existing)
    end

    it "persists rate from NBRB when missing" do
      allow(NbrbApiService).to receive(:get_rate).with("EUR", today).and_return(
        currency_code: "EUR",
        date: today,
        rate: 3.28,
        scale: 1
      )

      rate = described_class.fetch_or_create("EUR", today)

      expect(rate).to have_attributes(currency_code: "EUR", date: today, rate: 3.28, scale: 1)
      expect(described_class.current("EUR", today)).to eq(rate)
    end

    it "falls back to latest DB rate and copies it to today when NBRB fails" do
      previous = create_rate(code: "PLN", date: yesterday, rate: 7.6115, scale: 10)
      allow(NbrbApiService).to receive(:get_rate).with("PLN", today).and_return(nil)

      rate = described_class.fetch_or_create("PLN", today)

      expect(rate.date).to eq(today)
      expect(rate.rate).to eq(previous.rate)
      expect(rate.scale).to eq(previous.scale)
      expect(described_class.current("PLN", today)).to eq(rate)
    end

    it "opens circuit after NBRB failure when no DB fallback exists" do
      allow(NbrbApiService).to receive(:get_rate).once.and_return(nil)

      expect(described_class.fetch_or_create("EUR", today)).to be_nil
      expect(described_class.fetch_or_create("EUR", today)).to be_nil

      expect(NbrbApiService).to have_received(:get_rate).once
    end

    it "does not call NBRB again after fallback was persisted for today" do
      create_rate(code: "EUR", date: yesterday, rate: 3.28, scale: 1)
      allow(NbrbApiService).to receive(:get_rate).once.and_return(nil)

      first = described_class.fetch_or_create("EUR", today)
      second = described_class.fetch_or_create("EUR", today)

      expect(NbrbApiService).to have_received(:get_rate).once
      expect(first.date).to eq(today)
      expect(second).to eq(first)
    end

    it "returns previous rate for historical date without inventing a new date row" do
      previous = create_rate(code: "USD", date: yesterday - 1.day, rate: 2.86, scale: 1)
      allow(NbrbApiService).to receive(:get_rate).with("USD", yesterday).and_return(nil)

      rate = described_class.fetch_or_create("USD", yesterday)

      expect(rate).to eq(previous)
      expect(described_class.current("USD", yesterday)).to be_nil
    end
  end
end
