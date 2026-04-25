require "rails_helper"

RSpec.describe EuropostApiService do
  describe ".postal_create" do
    let(:http) { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPOK, body: '{"order_id":"12345"}') }
    let(:payload) do
      {
        "number" => "EP123",
        "is_relabeling" => true,
        "is_oversize" => "false",
        "is_completeness_check" => 1,
        "packing_payer" => "sender",
        "shipment_payer" => "recipient"
      }
    end

    before do
      allow(described_class).to receive(:jwt).and_return("test-jwt")
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:verify_mode=)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
    end

    it "posts to create endpoint with auth" do
      req = nil
      allow(http).to receive(:request) do |request|
        req = request
        response
      end

      result = described_class.postal_create(data: payload)

      expect(result["order_id"]).to eq("12345")
      expect(req).to be_a(Net::HTTP::Post)
      expect(req.path).to eq("/api/external/postal/create")
      expect(req["Authorization"]).to eq("Bearer test-jwt")
      expect(JSON.parse(req.body)).to eq(payload)
    end

    it "validates new optional fields" do
      invalid_payload = payload.merge("packing_payer" => "warehouse")

      expect {
        described_class.postal_create(data: invalid_payload)
      }.to raise_error(EuropostApiService::ValidationError, /packing_payer/)
    end
  end

  describe ".postal_payment_calculate" do
    let(:http) { instance_double(Net::HTTP) }
    let(:success_response) { instance_double(Net::HTTPOK, body: '{"total":12.4}') }
    let(:error_response) { instance_double(Net::HTTPBadRequest, body: '{"error":"bad request"}', code: "400", message: "Bad Request") }

    before do
      allow(described_class).to receive(:jwt).and_return("test-jwt")
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:verify_mode=)
    end

    it "calls payment calculate endpoint" do
      allow(success_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(success_response)

      result = described_class.postal_payment_calculate(data: { "weight" => 1.2 })

      expect(result).to include("total" => 12.4)
    end

    it "raises HttpError for non-success responses" do
      allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(error_response)

      expect {
        described_class.postal_payment_calculate(data: { "weight" => 1.2 })
      }.to raise_error(EuropostApiService::HttpError, /HTTP 400/)
    end

    it "validates payload type" do
      expect {
        described_class.postal_payment_calculate(data: [])
      }.to raise_error(EuropostApiService::ValidationError, /expects Hash payload/)
    end
  end
end
