require "rails_helper"

RSpec.describe Sendpulse::Client do
  let(:api_key) { "super-secret-key" }
  let(:base_url) { "https://api.sendpulse.com" }
  let(:client) { described_class.new(api_key: api_key, base_url: base_url) }

  describe "#post" do
    it "adds Authorization Bearer header" do
      stub = stub_request(:post, "#{base_url}/smtp/emails")
             .with(headers: { "Authorization" => "Bearer #{api_key}" })
             .to_return(status: 200, body: { ok: true }.to_json, headers: { "Content-Type" => "application/json" })

      client.post("/smtp/emails", foo: "bar")

      expect(stub).to have_been_requested
    end

    it "sends Content-Type application/json" do
      stub = stub_request(:post, "#{base_url}/smtp/emails")
             .with(headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: { ok: true }.to_json, headers: { "Content-Type" => "application/json" })

      client.post("/smtp/emails", foo: "bar")

      expect(stub).to have_been_requested
    end

    it "parses successful JSON response" do
      stub_request(:post, "#{base_url}/smtp/emails")
        .to_return(status: 200, body: { result: "ok" }.to_json, headers: { "Content-Type" => "application/json" })

      response = client.post("/smtp/emails", foo: "bar")

      expect(response).to eq({ "result" => "ok" })
    end

    it "raises custom error for failed response" do
      stub_request(:post, "#{base_url}/smtp/emails")
        .to_return(status: 500, body: { error: "internal_error" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { client.post("/smtp/emails", foo: "bar") }
        .to raise_error(Sendpulse::Error) do |error|
          expect(error.status).to eq(500)
          expect(error.endpoint).to eq("/smtp/emails")
          expect(error.response_body).to eq({ "error" => "internal_error" })
        end
    end

    it "does not log API key on error" do
      logged_message = nil
      allow(Rails.logger).to receive(:error) { |message| logged_message = message }
      stub_request(:post, "#{base_url}/smtp/emails")
        .to_return(status: 500, body: { error: "internal_error" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { client.post("/smtp/emails", foo: "bar") }.to raise_error(Sendpulse::Error)

      expect(logged_message).to be_present
      expect(logged_message).not_to include(api_key)
    end
  end
end
