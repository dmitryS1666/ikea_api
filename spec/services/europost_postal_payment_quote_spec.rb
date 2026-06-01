# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostPostalPaymentQuote do
  describe ".call" do
    let(:pln_rate_with_buffer) { 3.2 }

    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    it "returns token missing without calling API" do
      with_env("EUROPOST_API_TOKEN" => nil) do
        expect(EuropostApiService).not_to receive(:postal_payment_calculate)
        r = described_class.call(weight_kg: 2.5, pln_rate_with_buffer: pln_rate_with_buffer)

        expect(r[:success]).to be(false)
        expect(r[:reason]).to eq("europost_token_missing")
      end
    end

    it "builds API v1.8.2 payment payload and parses sender/receiver pays as BYN" do
      with_env(
        "EUROPOST_API_TOKEN" => "tok",
        "EUROPOST_STORE_ID_START" => "70130090",
        "EUROPOST_STORE_ID_FINISH" => nil,
        "EUROPOST_IS_JURISTIC" => "true",
        "EUROPOST_DELIVERY_TYPE" => nil,
        "EUROPOST_SHIPMENT_PAYER" => nil,
        "EUROPOST_CASH_ON_DELIVERY_PAYER" => nil
      ) do
        allow(EuropostApiService).to receive(:postal_payment_calculate)
          .and_return({ "sender_pays" => 4.5, "receiver_pays" => 10.0 })

        r = described_class.call(weight_kg: 10.0, pln_rate_with_buffer: pln_rate_with_buffer, pickup_point_id: "70130111")

        expect(r[:success]).to be(true)
        expect(r[:postal_total_byn]).to eq(14.5)
        expect(r[:payload]).to eq(
          "is_juristic" => true,
          "delivery_type" => 1,
          "store_id_start" => 70130090,
          "store_id_finish" => 70130111,
          "weight" => 10.0,
          "shipment_payer" => 0,
          "cash_on_delivery_payer" => 1
        )
      end
    end

    it "returns config error instead of calling API when required store ids are missing" do
      with_env(
        "EUROPOST_API_TOKEN" => "tok",
        "EUROPOST_STORE_ID_START" => nil,
        "EUROPOST_STORE_ID_FINISH" => nil
      ) do
        expect(EuropostApiService).not_to receive(:postal_payment_calculate)

        r = described_class.call(weight_kg: 5.0, pln_rate_with_buffer: pln_rate_with_buffer)

        expect(r[:success]).to be(false)
        expect(r[:reason]).to eq("europost_payload_missing_required_fields")
        expect(r[:error]).to include("EUROPOST_STORE_ID_START")
        expect(r[:error]).to include("pickup_point_id/EUROPOST_STORE_ID_FINISH")
      end
    end

    it "builds courier payload with delivery_type 2 without store_id_finish" do
      with_env(
        "EUROPOST_API_TOKEN" => "tok",
        "EUROPOST_STORE_ID_START" => "70130090",
        "EUROPOST_COURIER_DELIVERY_TYPE" => nil,
        "EUROPOST_DELIVERY_TYPE" => "1"
      ) do
        allow(EuropostApiService).to receive(:postal_payment_calculate)
          .and_return({ "sender_pays" => 8.0 })

        r = described_class.call(
          weight_kg: 5.0,
          pln_rate_with_buffer: pln_rate_with_buffer,
          delivery_kind: :courier,
          address: { europost_address_id: "90001" }
        )

        expect(r[:success]).to be(true)
        expect(r[:payload]).to include(
          "delivery_type" => 2,
          "store_id_start" => 70130090,
          "address_id" => 90001,
          "weight" => 5.0
        )
        expect(r[:payload]).not_to have_key("store_id_finish")
      end
    end

    it "converts PLN total to BYN when legacy total/currency response is used" do
      with_env(
        "EUROPOST_API_TOKEN" => "tok",
        "EUROPOST_STORE_ID_START" => "70130090",
        "EUROPOST_STORE_ID_FINISH" => "70130091"
      ) do
        allow(EuropostApiService).to receive(:postal_payment_calculate).and_return({ "total" => 10.0, "currency" => "PLN" })

        r = described_class.call(weight_kg: 5.0, pln_rate_with_buffer: 3.0)

        expect(r[:postal_total_byn]).to eq(30.0)
      end
    end
  end
end
