# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostPostalPaymentQuote do
  describe ".call" do
    let(:pln_rate_with_buffer) { 3.2 }

    it "returns token missing without calling API" do
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV.delete("EUROPOST_API_TOKEN")

      expect(EuropostApiService).not_to receive(:postal_payment_calculate)
      r = described_class.call(weight_kg: 2.5, pln_rate_with_buffer: pln_rate_with_buffer)

      expect(r[:success]).to be(false)
      expect(r[:reason]).to eq("europost_token_missing")
    ensure
      ENV["EUROPOST_API_TOKEN"] = prev if prev
    end

    it "parses total and treats as BYN when currency absent" do
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "tok"
      allow(EuropostApiService).to receive(:postal_payment_calculate).and_return({ "total" => 15.5 })

      r = described_class.call(weight_kg: 10.0, pln_rate_with_buffer: pln_rate_with_buffer)

      expect(r[:success]).to be(true)
      expect(r[:postal_total_byn]).to eq(15.5)
      expect(r[:payload]).to eq({ "weight" => 10.0 })
    ensure
      ENV["EUROPOST_API_TOKEN"] = prev if prev
    end

    it "converts PLN total to BYN" do
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "tok"
      allow(EuropostApiService).to receive(:postal_payment_calculate).and_return({ "total" => 10.0, "currency" => "PLN" })

      r = described_class.call(weight_kg: 5.0, pln_rate_with_buffer: 3.0)

      expect(r[:postal_total_byn]).to eq(30.0)
    ensure
      ENV["EUROPOST_API_TOKEN"] = prev if prev
    end
  end
end
