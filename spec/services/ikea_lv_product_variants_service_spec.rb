# frozen_string_literal: true

require "rails_helper"

RSpec.describe IkeaLvProductVariantsService do
  let(:product) { instance_double(Product, sku: "s29545213", id: 1, name_ru: "VIMLE") }
  let(:service) { described_class.new(product: product, force: true) }

  before do
    allow(Product).to receive(:find_by).and_return(nil)
  end

  describe "#extract_sku_from_url (private)" do
    it "parses PL article id with s prefix" do
      url = "https://www.ikea.com/pl/pl/p/vimle-sofa-s29537086/#content"
      expect(service.send(:extract_sku_from_url, url)).to eq("s29537086")
    end

    it "parses 8-digit suffix without s" do
      url = "https://www.ikea.com/lt/ru/p/foo-barsloev-80541594/"
      expect(service.send(:extract_sku_from_url, url)).to eq("80541594")
    end
  end

  describe "#extract_color_variants (private)" do
    let(:html) do
      <<~HTML
        <div class="pipf-product-style-picker">
          <div class="pipf-product-style-picker__picker">
            <ul class="pipf-product-style-picker__items">
              <li class="pipf-product-style-picker__box">
                <div aria-label="Current beż" class="pipf-product-style-picker__item pipf-product-style-picker__item--selected">
                  <img class="pipf-image" src="https://www.ikea.com/pl/pl/images/products/a__0952222_pe801646_s5.jpg?f=xu" alt="x" />
                </div>
              </li>
              <li class="pipf-product-style-picker__box">
                <a aria-label="Hallarp szary" href="https://www.ikea.com/pl/pl/p/vimle-prod-s29537086/#content" class="pipf-product-style-picker__link">
                  <div class="pipf-product-style-picker__item">
                    <img class="pipf-image" src="https://www.ikea.com/pl/pl/images/products/b__0952230_pe801662_s5.jpg?f=xu" alt="y" />
                  </div>
                </a>
              </li>
            </ul>
          </div>
        </div>
      HTML
    end

    it "collects selected and linked covers with SKUs and preview images" do
      doc = Nokogiri::HTML(html)
      rows = service.send(:extract_color_variants, doc)
      expect(rows.size).to eq(2)
      skus = rows.map { |r| r.dig(:item, :sku) }
      expect(skus).to contain_exactly("s29545213", "s29537086")
      linked = rows.find { |r| r.dig(:item, :sku) == "s29537086" }
      expect(linked[:color]).to include("Hallarp")
      expect(linked.dig(:item, :images).first).to include("0952230_pe801662")
    end
  end
end
