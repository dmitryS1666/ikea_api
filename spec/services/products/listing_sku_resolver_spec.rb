# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ListingSkuResolver do
  describe ".coerce_listing_identifier" do
    it "returns first sku from array id" do
      expect(described_class.coerce_listing_identifier(%w[s11111111 s22222222])).to eq("s11111111")
    end

    it "parses stringified JSON array" do
      raw = %w[s11111111 s22222222].to_s
      expect(described_class.coerce_listing_identifier(raw)).to eq("s11111111")
    end

    it "extracts id from hash" do
      expect(described_class.coerce_listing_identifier("sku" => "s33333333")).to eq("s33333333")
    end

    it "returns nil for blank" do
      expect(described_class.coerce_listing_identifier(nil)).to be_nil
      expect(described_class.coerce_listing_identifier([])).to be_nil
    end
  end

  describe ".aliases" do
    it "returns s-prefixed, bare, and s+core variants" do
      expect(described_class.aliases("s29545213")).to contain_exactly("s29545213", "29545213")
      expect(described_class.aliases("29545213")).to contain_exactly("29545213", "s29545213")
    end

    it "extracts article from public product slug with s-prefixed sku" do
      expect(described_class.aliases("saltsjobaden-s79578593")).to include("s79578593", "79578593")
    end

    it "extracts article from canonical public product slug" do
      expect(described_class.aliases("saltsjobaden-79578593")).to include("s79578593", "79578593")
    end
  end

  describe Products::PublicProductUrl do
    it "returns URL-safe sku core without s prefix" do
      expect(described_class.sku_core("s79578593")).to eq("79578593")
      expect(described_class.sku_core("79578593")).to eq("79578593")
    end

    it "collapses repeated slug tokens for public URL" do
      product = build(:product, sku: "s39491276", name: "LANDSKRONA")
      allow(product).to receive(:cached_slug).and_return(((["landskrona"] * 120) + ["s39491276"]).join("-"))

      expect(described_class.public_slug(product)).to eq("landskrona-s39491276")
      expect(described_class.path(product)).to eq("/product/landskrona-s39491276-39491276/")
    end

    it "limits very long public slugs" do
      product = build(:product, sku: "79578593", name: "Very long sofa bed with many extra words and repeated commercial description for frontend card")

      expect(described_class.public_slug(product).length).to be <= described_class::MAX_SLUG_LENGTH
    end
  end

  describe ".find_product" do
    it "finds by listing sku when DB stores without s prefix" do
      p = create(:product, sku: "29545213")
      expect(described_class.find_product("s29545213")).to eq(p)
    end

    it "finds by listing sku when DB stores with s prefix" do
      p = create(:product, sku: "s29545213")
      expect(described_class.find_product("29545213")).to eq(p)
    end

    it "finds product by public slug with s-prefixed article" do
      p = create(:product, sku: "s79578593", name: "SALTSJÖBADEN")
      expect(described_class.find_product("saltsjobaden-s79578593")).to eq(p)
    end

    it "finds product by canonical public slug without s prefix" do
      p = create(:product, sku: "s79578593", name: "SALTSJÖBADEN")
      expect(described_class.find_product("saltsjobaden-79578593")).to eq(p)
    end
  end
end
