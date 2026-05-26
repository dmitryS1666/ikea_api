# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::StructuredData::ProductBuilder do
  let(:product) { create(:product, sku: "30566134", name: "LYNGÖR", price: 100, quantity: 5) }

  before do
    ExchangeRate.create!(
      date: Date.today,
      currency_code: "PLN",
      rate: 7.5,
      official_rate: 7.5,
      scale: 1
    )
  end

  it "returns Product schema hash" do
    payload = described_class.build(product, site_url: "https://test.ikeya.by", city_code: "minsk")

    expect(payload["@type"]).to eq("Product")
    expect(payload["sku"]).to eq("30566134")
    expect(payload["url"]).to include("/product/")
    expect(payload["url"]).to include("30566134")
    expect(payload.dig("offers", "priceCurrency")).to eq("BYN")
  end
end
