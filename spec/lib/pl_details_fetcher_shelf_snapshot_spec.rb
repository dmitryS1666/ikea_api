# frozen_string_literal: true

require "rails_helper"

RSpec.describe PlDetailsFetcher, "#shelf_snapshot_pln_price_from_json_ld" do
  subject(:fetcher) { described_class.new }

  let(:base_product) do
    {
      "@context" => "https://schema.org",
      "@type" => "Product",
      "name" => "Sample",
      "mpn" => "19485139"
    }
  end

  it "берёт цену при единственном PLN-offer" do
    schema = base_product.merge(
      "offers" => {
        "@type" => "Offer",
        "priceCurrency" => "PLN",
        "price" => 3798
      }
    )
    expect(fetcher.shelf_snapshot_pln_price_from_json_ld(schema, page_item_token: nil)).to eq(3798)
  end

  it "при нескольких PLN-offer без токена страницы не выбирает цену" do
    schema = base_product.merge(
      "offers" => {
        "@type" => "AggregateOffer",
        "priceCurrency" => "PLN",
        "offers" => [
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 100, "sku" => "00528940" },
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 3798, "sku" => "19485139" }
        ]
      }
    )
    expect(fetcher.shelf_snapshot_pln_price_from_json_ld(schema, page_item_token: nil)).to be_nil
  end

  it "при нескольких PLN-offer выбирает цену по артикулу страницы (sku)" do
    schema = base_product.merge(
      "offers" => {
        "@type" => "AggregateOffer",
        "offers" => [
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 100, "sku" => "00528940" },
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 3798, "sku" => "19485139" }
        ]
      }
    )
    expect(fetcher.shelf_snapshot_pln_price_from_json_ld(schema, page_item_token: "19485139")).to eq(3798)
  end

  it "сопоставляет артикул страницы s… с sku без префикса s" do
    schema = base_product.merge(
      "offers" => {
        "@type" => "AggregateOffer",
        "offers" => [
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 100, "sku" => "00528940" },
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 3798, "sku" => "19485139" }
        ]
      }
    )
    expect(fetcher.shelf_snapshot_pln_price_from_json_ld(schema, page_item_token: "s19485139")).to eq(3798)
  end

  it "при нескольких совпадениях по токену не угадывает" do
    schema = base_product.merge(
      "offers" => {
        "@type" => "AggregateOffer",
        "offers" => [
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 100, "sku" => "19485139" },
          { "@type" => "Offer", "priceCurrency" => "PLN", "price" => 200, "sku" => "19485139" }
        ]
      }
    )
    expect(fetcher.shelf_snapshot_pln_price_from_json_ld(schema, page_item_token: "19485139")).to be_nil
  end
end

RSpec.describe PlDetailsFetcher, "#shelf_snapshot_page_item_token" do
  subject(:fetcher) { described_class.new }

  it "достаёт артикул из хвоста URL" do
    expect(fetcher.shelf_snapshot_page_item_token("https://www.ikea.com/pl/pl/p/x-s19485139/")).to eq("s19485139")
    expect(fetcher.shelf_snapshot_page_item_token("https://www.ikea.com/pl/pl/p/foo-19485139")).to eq("19485139")
  end
end
