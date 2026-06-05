# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::EuropostTesterService do
  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe ".load_stores" do
    it "loads and normalizes Europost stores" do
      allow(EuropostApiService).to receive(:external_stores).with(type: "1").and_return(
        [
          { "id" => 70130090, "name" => "ОПС №1", "city" => "Минск", "address" => "ул. Ленина, 1" }
        ]
      )

      stores = described_class.load_stores(type: "1")

      expect(stores.first).to include(id: "70130090", name: "ОПС №1", city: "Минск", address: "ул. Ленина, 1")
    end
  end

  describe ".calculate" do
    it "calls postal payment calculate and returns amount" do
      allow(EuropostApiService).to receive(:postal_payment_calculate).and_return(
        "shipment_price" => 8.5,
        "currency" => "BYN"
      )

      result = described_class.calculate(
        "delivery_kind" => "pickup",
        "store_id_start" => "70130090",
        "store_id_finish" => "70130091",
        "weight" => "1.5",
        "shipment_payer" => "0",
        "cash_on_delivery_payer" => "1"
      )

      expect(result).to be_success
      expect(result.status).to eq(:calculated)
      expect(result.amount).to eq(8.5)
      expect(result.currency).to eq("BYN")
      expect(EuropostApiService).to have_received(:postal_payment_calculate).with(
        data: a_hash_including(
          "delivery_type" => 1,
          "store_id_start" => 70130090,
          "store_id_finish" => 70130091,
          "weight" => 1.5
        )
      )
    end
  end

  describe ".create_shipment" do
    let(:params) do
      {
        "delivery_kind" => "pickup",
        "store_id_start" => "70130090",
        "store_id_finish" => "70130091",
        "weight" => "1.5",
        "length" => "30",
        "width" => "20",
        "height" => "10",
        "receiver_phone_number" => "+375 (29) 123-45-67",
        "receiver_name" => "Иван",
        "receiver_surname" => "Иванов",
        "contractor_unn" => "193323100",
        "external_id" => "IKEYA-TEST-1",
        "confirm_create" => "1"
      }
    end

    it "creates postal item and returns track number only after confirmation" do
      allow(EuropostApiService).to receive(:postal_create).and_return("number" => "BY080027046773")

      result = described_class.create_shipment(params)

      expect(result).to be_success
      expect(result.status).to eq(:created)
      expect(result.track_number).to eq("BY080027046773")
      expect(EuropostApiService).to have_received(:postal_create).with(
        data: a_hash_including(
          "delivery_type" => 1,
          "store_id_start" => 70130090,
          "store_id_finish" => 70130091,
          "receiver_phone_number" => "375291234567",
          "contractor_unn" => 193323100
        )
      )
    end

    it "does not create postal item without confirmation checkbox" do
      allow(EuropostApiService).to receive(:postal_create)

      result = described_class.create_shipment(params.except("confirm_create"))

      expect(result.success?).to eq(false)
      expect(result.status).to eq(:confirmation_required)
      expect(EuropostApiService).not_to have_received(:postal_create)
    end
  end
end
