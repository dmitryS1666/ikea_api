# frozen_string_literal: true

require "rails_helper"

RSpec.describe AsteriskCallAuthService do
  around do |example|
    old_url = ENV["ASTERISK_CALL_AUTH_URL"]
    old_token = ENV["ASTERISK_CALL_AUTH_TOKEN"]
    old_from_numbers = ENV["ASTERISK_CALL_AUTH_FROM_NUMBERS"]
    old_timeout = ENV["ASTERISK_CALL_AUTH_TIMEOUT"]

    ENV.delete("ASTERISK_CALL_AUTH_URL")
    ENV.delete("ASTERISK_CALL_AUTH_TOKEN")
    ENV.delete("ASTERISK_CALL_AUTH_FROM_NUMBERS")
    ENV.delete("ASTERISK_CALL_AUTH_TIMEOUT")

    example.run
  ensure
    restore_env("ASTERISK_CALL_AUTH_URL", old_url)
    restore_env("ASTERISK_CALL_AUTH_TOKEN", old_token)
    restore_env("ASTERISK_CALL_AUTH_FROM_NUMBERS", old_from_numbers)
    restore_env("ASTERISK_CALL_AUTH_TIMEOUT", old_timeout)
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  describe ".available_numbers" do
    it "uses the new Asterisk caller pool by default" do
      expect(described_class.available_numbers).to eq(
        %w[
          +375255361737
          +375255361738
          +375255361739
          +375255361740
          +375255361741
          +375255361742
          +375255361743
          +375255361744
          +375255361745
          +375255361746
        ]
      )
    end

    it "allows overriding caller numbers from ENV" do
      ENV["ASTERISK_CALL_AUTH_FROM_NUMBERS"] = "+375291111111, +375292222222"

      expect(described_class.available_numbers).to eq(%w[+375291111111 +375292222222])
    end
  end

  describe ".get_caller_info" do
    it "returns a caller number and last four digits as verification code" do
      allow(described_class).to receive(:available_numbers).and_return(["+375255361737"])

      expect(described_class.get_caller_info).to eq(number: "+375255361737", code: "1737")
    end
  end

  describe ".initiate_call" do
    it "posts to the new Asterisk endpoint with bearer auth and from/to numbers" do
      ENV["ASTERISK_CALL_AUTH_TOKEN"] = "test-token"

      request = stub_request(:post, "https://box.asterisk.by/call/auth")
        .with(
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer test-token"
          },
          body: {
            from: "+375255361737",
            to: "+375293363388"
          }.to_json
        )
        .to_return(
          status: 200,
          body: { status: "accepted" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = described_class.initiate_call(
        to_phone: "+375293363388",
        from_number: "+375255361737"
      )

      expect(result).to include(success: true, from: "+375255361737", to: "+375293363388")
      expect(request).to have_been_requested
    end

    it "returns a clear error when token is not configured" do
      result = described_class.initiate_call(
        to_phone: "+375293363388",
        from_number: "+375255361737"
      )

      expect(result).to eq(success: false, error: "Не задан ASTERISK_CALL_AUTH_TOKEN")
    end

    it "normalizes user phone to E.164-like format" do
      ENV["ASTERISK_CALL_AUTH_TOKEN"] = "test-token"

      request = stub_request(:post, "https://box.asterisk.by/call/auth")
        .with(body: { from: "+375255361737", to: "+375293363388" }.to_json)
        .to_return(
          status: 200,
          body: { status: "accepted" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      described_class.initiate_call(
        to_phone: "375 (29) 336-33-88",
        from_number: "375255361737"
      )

      expect(request).to have_been_requested
    end
  end
end
