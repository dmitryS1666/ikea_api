# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ListingSkuResolver do
  describe ".aliases" do
    it "returns s-prefixed, bare, and s+core variants" do
      expect(described_class.aliases("s29545213")).to contain_exactly("s29545213", "29545213")
      expect(described_class.aliases("29545213")).to contain_exactly("29545213", "s29545213")
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
  end
end
