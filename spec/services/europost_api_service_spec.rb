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

  describe ".external_stores" do
    around do |example|
      previous = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "test-store-token"
      example.run
    ensure
      if previous
        ENV["EUROPOST_API_TOKEN"] = previous
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end

    it "GETs /api/external/stores with Token header and type query" do
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query == "type=3" }
        .to_return(status: 200, body: [{ "id" => 40130190, "working_hours" => "10-22" }].to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.external_stores(type: "3")

      expect(result).to eq([{ "id" => 40130190, "working_hours" => "10-22" }])
    end

    it "unwraps stores array from JSON object" do
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query.nil? || URI(req.uri).query.empty? }
        .to_return(status: 200, body: { "stores" => [{ "id" => 2 }] }.to_json, headers: { "Content-Type" => "application/json" })

      expect(described_class.external_stores).to eq([{ "id" => 2 }])
    end
  end

  describe ".external_stores_for_merge" do
    around do |example|
      previous = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "test-store-token"
      example.run
    ensure
      if previous
        ENV["EUROPOST_API_TOKEN"] = previous
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end

    it "loads types 1, 3, 4 and dedupes by id when type is omitted" do
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query == "type=1" }
        .to_return(status: 200, body: [{ "id" => 1, "working_hours" => "A" }].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query == "type=3" }
        .to_return(status: 200, body: [{ "id" => 2 }].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query == "type=4" }
        .to_return(status: 200, body: [{ "id" => 1, "schedules" => [{ "work_time" => "9-17" }] }].to_json, headers: { "Content-Type" => "application/json" })

      list = described_class.external_stores_for_merge(type: nil)

      expect(list.size).to eq(2)
      one = list.find { |r| r["id"] == 1 }
      expect(one["schedules"]).to be_present
    end

    it "uses a single typed request when type is set" do
      stub_request(:get, %r{/api/external/stores})
        .with { |req| URI(req.uri).query == "type=3" }
        .to_return(status: 200, body: [{ "id" => 9 }].to_json, headers: { "Content-Type" => "application/json" })

      list = described_class.external_stores_for_merge(type: "3")

      expect(list).to eq([{ "id" => 9 }])
    end
  end
end
