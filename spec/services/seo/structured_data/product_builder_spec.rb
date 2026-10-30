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
    payload = described_class.build(product, site_url: "https://ikeya.by", city_code: "minsk")

    expect(payload["@type"]).to eq("Product")
    expect(payload["sku"]).to eq("30566134")
    expect(payload["url"]).to include("/product/")
    expect(payload["url"]).to include("30566134")
    expect(payload.dig("offers", "priceCurrency")).to eq("BYN")
  end
  it "publishes Product.url and every Offer.url on the public site" do
    payload = described_class.build(
      product,
      site_url: "http://host.docker.internal:3001",
      city_code: "minsk"
    )

    expect(payload["url"]).to start_with("https://ikeya.by/product/")
    expect(payload["url"]).to end_with("30566134/")
    expect(payload["url"]).not_to include("docker")
    expect(payload.dig("offers", "url")).to eq(payload["url"])
  end

  it "rewrites each nested offer url to the public product page" do
    page_url = "https://ikeya.by/product/forsa-30439117/"
    builder = described_class.new(product, site_url: "http://host.docker.internal:3001")
    offers = builder.send(
      :rewrite_offer_urls,
      {
        "@type" => "AggregateOffer",
        "url" => "http://host.docker.internal:3001/product/forsa-30439117/",
        "offers" => [
          { "@type" => "Offer", "url" => "http://host.docker.internal:3001/product/forsa-30439117/" },
          { "@type" => "Offer", "url" => "http://10.0.0.8:3001/product/other/" }
        ]
      },
      page_url
    )

    expect(offers["url"]).to eq(page_url)
    expect(offers["offers"].map { |offer| offer["url"] }).to all(eq(page_url))
  end

  it "uses full product name in Product schema" do
    product.update!(name: "PAX", name_ru: "PAX", small_desc_name: "Гардероб, комбинация")

    payload = described_class.build(product.reload, site_url: "https://ikeya.by", city_code: "minsk")

    expect(payload["name"]).to eq("PAX Гардероб, комбинация")
  end

end
