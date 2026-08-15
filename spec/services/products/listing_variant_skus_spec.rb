# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ListingVariantSkus do
  let(:parent) { "s99614849" }
  let(:row) do
    {
      "id" => parent,
      "gprDescription" => {
        "variants" => [
          { "id" => parent, "pipUrl" => "https://www.ikea.com/pl/pl/p/gullaberg-#{parent}/" },
          { "id" => "s69614742", "pipUrl" => "https://www.ikea.com/pl/pl/p/gullaberg-s69614742/" },
          { "id" => "s39614753", "pipUrl" => "https://www.ikea.com/pl/pl/p/gullaberg-s39614753/" },
          { "itemNo" => "20608926" },
          { "id" => "not-a-sku", "pipUrl" => "https://www.ikea.com/pl/pl/p/x/" }
        ],
        "variations" => [
          {
            "code" => "COLOUR",
            "values" => [
              { "products" => %w[69614742 39614753 11111111 22222222 33333333 44444444 55555555 66666666 77777777] }
            ]
          }
        ]
      }
    }
  end

  it "takes pip variants from the listing row and skips the parent" do
    expect(described_class.from_listing_row(row, parent_sku: parent)).to eq(%w[s69614742 s39614753])
  end

  it "does not expand the variations matrix into extra SKUs" do
    skus = described_class.from_listing_row(row, parent_sku: parent)
    expect(skus).not_to include("11111111", "s11111111")
  end

  it "excludes other listing tiles of the same category" do
    skus = described_class.from_listing_row(row, parent_sku: parent, exclude: %w[s39614753])
    expect(skus).to eq(%w[s69614742])
  end

  it "caps extras per parent" do
    variants = (1..20).map do |i|
      sku = format("s%08d", i)
      { "id" => sku, "pipUrl" => "https://www.ikea.com/pl/pl/p/x-#{sku}/" }
    end
    data = { "gprDescription" => { "variants" => variants } }

    expect(described_class.from_listing_row(data, parent_sku: "s99999999").size)
      .to eq(described_class::MAX_PER_PARENT)
  end
end
