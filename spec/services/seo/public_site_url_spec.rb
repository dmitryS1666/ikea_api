# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::PublicSiteUrl do
  around do |example|
    previous = ENV["PUBLIC_SITE_URL"]
    example.run
  ensure
    ENV["PUBLIC_SITE_URL"] = previous
  end

  describe ".resolve" do
    it "uses the configured public origin" do
      ENV["PUBLIC_SITE_URL"] = "https://ikeya.by/"

      request = instance_double(ActionDispatch::Request, base_url: "http://host.docker.internal:3001")

      expect(described_class.resolve(request)).to eq("https://ikeya.by")
    end

    it "ignores an internal request host and unverified Host header" do
      ENV["PUBLIC_SITE_URL"] = nil
      request = instance_double(
        ActionDispatch::Request,
        base_url: "http://host.docker.internal:3001",
        host: "host.docker.internal",
        headers: { "Host" => "host.docker.internal:3001", "X-Forwarded-Host" => "host.docker.internal" }
      )

      expect(described_class.resolve(request)).to eq("https://ikeya.by")
    end

    it "rejects an internal PUBLIC_SITE_URL" do
      ENV["PUBLIC_SITE_URL"] = "http://host.docker.internal:3001"

      expect(described_class.resolve).to eq("https://ikeya.by")
    end
  end

  describe ".coerce" do
    it "keeps a public https origin and replaces an internal one" do
      ENV["PUBLIC_SITE_URL"] = nil

      expect(described_class.coerce("https://ikeya.by/")).to eq("https://ikeya.by")
      expect(described_class.coerce("http://10.0.0.8:3001")).to eq("https://ikeya.by")
    end
  end
end
