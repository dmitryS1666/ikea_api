# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::RemoteContentLength do
  let(:url) { "https://www.ikea.com/pvid/clip.mp4" }
  let(:uri) { URI.parse(url) }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(ProxyRotator).to receive(:with_proxy_retry).and_yield(nil)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  it "returns Content-Length from HEAD" do
    head = Net::HTTPSuccess.new("1.1", "200", "OK")
    allow(head).to receive(:[]).with("content-range").and_return(nil)
    allow(head).to receive(:[]).with("content-length").and_return("4096")
    allow(http).to receive(:request).and_return(head)

    expect(described_class.fetch(url)).to eq(4096)
  end

  it "falls back to Content-Range when HEAD has no length" do
    head = Net::HTTPSuccess.new("1.1", "200", "OK")
    allow(head).to receive(:[]).with("content-range").and_return(nil)
    allow(head).to receive(:[]).with("content-length").and_return(nil)

    ranged = Net::HTTPSuccess.new("1.1", "206", "Partial Content")
    allow(ranged).to receive(:[]).with("content-range").and_return("bytes 0-0/1048576")
    allow(ranged).to receive(:[]).with("content-length").and_return("1")

    allow(http).to receive(:request).and_return(head, ranged)

    expect(described_class.fetch(url)).to eq(1_048_576)
  end

  it "returns nil for 404 without raising" do
    missing = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    allow(missing).to receive(:[]).with("content-range").and_return(nil)
    allow(missing).to receive(:[]).with("content-length").and_return(nil)
    allow(http).to receive(:request).and_return(missing, missing)

    expect(described_class.fetch(url)).to be_nil
  end
end
