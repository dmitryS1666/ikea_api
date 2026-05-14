# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostApiService do
  let(:default_base) { "https://api-kassa.evropochta.by" }

  describe ".rest_api_base_url" do
    it "defaults to api-kassa.evropochta.by" do
      prev = ENV["EUROPOST_API_BASE_URL"]
      ENV.delete("EUROPOST_API_BASE_URL")
      expect(described_class.rest_api_base_url).to eq(default_base)
    ensure
      ENV["EUROPOST_API_BASE_URL"] = prev if prev
    end

    it "strips trailing slash from EUROPOST_API_BASE_URL" do
      prev = ENV["EUROPOST_API_BASE_URL"]
      ENV["EUROPOST_API_BASE_URL"] = "https://example.com/api/"
      expect(described_class.rest_api_base_url).to eq("https://example.com/api")
    ensure
      if prev
        ENV["EUROPOST_API_BASE_URL"] = prev
      else
        ENV.delete("EUROPOST_API_BASE_URL")
      end
    end
  end

  describe ".postal_create" do
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

    around do |example|
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "test-rest-token"
      example.run
    ensure
      if prev
        ENV["EUROPOST_API_TOKEN"] = prev
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end

    it "POSTs to create endpoint with Token header on REST base URL" do
      stub_request(:post, "#{default_base}/api/external/postal/create")
        .with(
          headers: {
            "Accept" => "application/json",
            "Content-Type" => %r{application/json},
            "Token" => "test-rest-token"
          }
        ) { |req| JSON.parse(req.body) == payload }
        .to_return(status: 200, body: { "order_id" => "12345" }.to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.postal_create(data: payload)

      expect(result["order_id"]).to eq("12345")
      expect(WebMock).to have_requested(:post, "#{default_base}/api/external/postal/create")
    end

    it "raises ValidationError when EUROPOST_API_TOKEN is blank" do
      ENV.delete("EUROPOST_API_TOKEN")

      expect {
        described_class.postal_create(data: payload)
      }.to raise_error(EuropostApiService::ValidationError, /EUROPOST_API_TOKEN/)
    end

    it "validates new optional fields" do
      invalid_payload = payload.merge("packing_payer" => "warehouse")

      expect {
        described_class.postal_create(data: invalid_payload)
      }.to raise_error(EuropostApiService::ValidationError, /packing_payer/)
    end

    it "raises UnauthorizedError on HTTP 401" do
      stub_request(:post, "#{default_base}/api/external/postal/create")
        .to_return(status: 401, body: { "error" => "unauthorized" }.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        described_class.postal_create(data: payload)
      }.to raise_error(EuropostApiService::UnauthorizedError, /401/)
    end

    it "raises NonJsonResponseError when body is HTML" do
      stub_request(:post, "#{default_base}/api/external/postal/create")
        .to_return(
          status: 200,
          body: "<HTML><BODY><B>200 OK</B></BODY></HTML>",
          headers: { "Content-Type" => "text/html" }
        )

      expect {
        described_class.postal_create(data: payload)
      }.to raise_error(EuropostApiService::NonJsonResponseError, /non-JSON/)
    end
  end

  describe ".postal_payment_calculate" do
    around do |example|
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "pay-token"
      example.run
    ensure
      if prev
        ENV["EUROPOST_API_TOKEN"] = prev
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end

    it "calls payment calculate endpoint with Token" do
      stub_request(:post, "#{default_base}/api/external/postal/payment/calculate")
        .with(headers: { "Token" => "pay-token" }, body: { "weight" => 1.2 }.to_json)
        .to_return(status: 200, body: { "total" => 12.4 }.to_json, headers: { "Content-Type" => "application/json" })

      result = described_class.postal_payment_calculate(data: { "weight" => 1.2 })

      expect(result).to include("total" => 12.4)
    end

    it "raises HttpError for non-success responses" do
      stub_request(:post, "#{default_base}/api/external/postal/payment/calculate")
        .to_return(status: 400, body: { "error" => "bad request" }.to_json, headers: { "Content-Type" => "application/json" })

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

    it "GETs stores on api-kassa.evropochta.by with Token header and type query" do
      stub_request(:get, "#{default_base}/api/external/stores")
        .with(
          headers: { "Token" => "test-store-token", "Accept" => "application/json" },
          query: { "type" => "1" }
        )
        .to_return(
          status: 200,
          body: [{ "id" => 70132570, "working_hours" => "09:00-21:00", "break_hours" => "14:00-15:00", "breaks" => [], "schedules" => [{ "work_time" => "09:00-21:00", "lunch_time" => "14:00-15:00", "iso_day_of_week" => 4 }] }].to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = described_class.external_stores(type: "1")

      expect(result.size).to eq(1)
      row = result.first
      expect(row["working_hours"]).to eq("09:00-21:00")
      expect(row["schedules"]).to be_an(Array)
      expect(row["schedules"].first["iso_day_of_week"]).to eq(4)
      expect(WebMock).to have_requested(:get, "#{default_base}/api/external/stores").with(query: { "type" => "1" })
    end

    it "returns empty array on 401 without raising" do
      stub_request(:get, "#{default_base}/api/external/stores")
        .to_return(status: 401, body: { "error" => "bad token" }.to_json, headers: { "Content-Type" => "application/json" })

      expect(described_class.external_stores).to eq([])
    end

    it "returns empty array on non-JSON HTML response" do
      stub_request(:get, "#{default_base}/api/external/stores")
        .to_return(
          status: 200,
          body: "<HTML><BODY><B>200 OK</B></BODY></HTML>",
          headers: { "Content-Type" => "text/html" }
        )

      expect(described_class.external_stores).to eq([])
    end

    it "unwraps stores array from JSON object" do
      stub_request(:get, "#{default_base}/api/external/stores")
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
      stub_request(:get, "#{default_base}/api/external/stores")
        .with(query: { "type" => "1" })
        .to_return(status: 200, body: [{ "id" => 1, "working_hours" => "A" }].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{default_base}/api/external/stores")
        .with(query: { "type" => "3" })
        .to_return(status: 200, body: [{ "id" => 2 }].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{default_base}/api/external/stores")
        .with(query: { "type" => "4" })
        .to_return(status: 200, body: [{ "id" => 1, "schedules" => [{ "work_time" => "9-17" }] }].to_json, headers: { "Content-Type" => "application/json" })

      list = described_class.external_stores_for_merge(type: nil)

      expect(list.size).to eq(2)
      one = list.find { |r| r["id"] == 1 }
      expect(one["schedules"]).to be_present
    end

    it "uses a single typed request when type is set" do
      stub_request(:get, "#{default_base}/api/external/stores")
        .with(query: { "type" => "3" })
        .to_return(status: 200, body: [{ "id" => 9 }].to_json, headers: { "Content-Type" => "application/json" })

      list = described_class.external_stores_for_merge(type: "3")

      expect(list).to eq([{ "id" => 9 }])
    end
  end
end
