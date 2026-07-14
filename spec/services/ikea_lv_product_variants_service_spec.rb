# frozen_string_literal: true

require "rails_helper"

RSpec.describe IkeaLvProductVariantsService do
  let(:product) do
    instance_double(Product, sku: "s29545213", id: 1, name: "VIMLE", name_ru: "VIMLE")
  end
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

    it "collects selected and linked covers with SKUs only" do
      doc = Nokogiri::HTML(html)
      rows = service.send(:extract_color_variants, doc)
      expect(rows.size).to eq(2)
      skus = rows.map { |r| r.dig(:item, :sku) }
      expect(skus).to contain_exactly("s29545213", "s29537086")
      linked = rows.find { |r| r.dig(:item, :sku) == "s29537086" }
      expect(linked[:color]).to include("Hallarp")
      expect(linked.dig(:item, :images)).to eq(
        ["https://www.ikea.com/pl/pl/images/products/b__0952230_pe801662_s5.jpg"]
      )
    end
  end

  describe "#extract_variants hydration payload" do
    let(:html) do
      payload = {
        "data" => {
          "productStylePickerProps" => {
            "variationStyles" => [
              {
                "title" => "Wybierz kolor",
                "selectedOption" => "Żółty",
                "code" => "COLOUR",
                "allOptions" => [
                  {
                    "title" => "Głęboka czerwień",
                    "linkId" => "20614376",
                    "url" => "https://www.ikea.com/pl/pl/p/gulvial-czerwony-20614376/",
                    "valueImage" => { "url" => "https://www.ikea.com/red.jpg" }
                  },
                  {
                    "title" => "Żółty",
                    "linkId" => "00614358",
                    "url" => "https://www.ikea.com/pl/pl/p/gulvial-zolty-00614358/",
                    "valueImage" => { "url" => "https://www.ikea.com/yellow.jpg" }
                  }
                ]
              }
            ]
          },
          "productSpecificationSectionProps" => {
            "variations" => [
              {
                "title" => "Wybierz rozmiar",
                "selectedOption" => "70x140 cm",
                "code" => "SIZE",
                "options" => [
                  {
                    "title" => "30x30 cm",
                    "linkId" => "10614372",
                    "url" => "https://www.ikea.com/pl/pl/p/gulvial-zolty-10614372/"
                  },
                  {
                    "title" => "70x140 cm",
                    "linkId" => "00614358",
                    "url" => "https://www.ikea.com/pl/pl/p/gulvial-zolty-00614358/"
                  }
                ]
              }
            ]
          }
        }
      }

      <<~HTML
        <html>
          <body>
            <script type="text/hydrate">#{JSON.generate(payload)}</script>
            <div class="pipf-product-variation-section">
              <div class="pipf-seo-content">
                <a href="/pl/pl/p/gulvial-czerwony-70614388/">50x100 cm</a>
              </div>
            </div>
          </body>
        </html>
      HTML
    end

    before do
      allow(service).to receive(:variant_payload) do |_variant_product, sku, cover_label:, preview_images: []|
        { sku: sku, small_desc_name: cover_label, images: preview_images }
      end
    end

    it "prefers current color-specific structured variants over legacy HTML" do
      groups = service.send(:extract_variants, Nokogiri::HTML(html))

      expect(groups.map { |group| group[:type] }).to eq(%w[color size])

      colors = groups.find { |group| group[:type] == "color" }[:data]
      expect(colors.map { |row| row[:color] }).to eq(["Głęboka czerwień", "Żółty"])
      expect(colors.map { |row| row.dig(:item, :sku) }).to eq(%w[20614376 00614358])

      sizes = groups.find { |group| group[:type] == "size" }[:data]
      expect(sizes.map { |row| row[:size] }).to eq(["30x30 cm", "70x140 cm"])
      expect(sizes.map { |row| row.dig(:item, :sku) }).to eq(%w[10614372 00614358])
      expect(sizes.map { |row| row.dig(:item, :sku) }).not_to include("70614388")
    end

    it "falls back to legacy HTML when hydration JSON is invalid" do
      invalid_html = <<~HTML
        <html>
          <body>
            <script type="text/hydrate">{"productStylePickerProps":</script>
            <div class="pipf-product-variation-section">
              <div class="pipf-seo-content">
                <a href="/pl/pl/p/gulvial-zolty-10614372/">30x30 cm</a>
              </div>
            </div>
          </body>
        </html>
      HTML

      groups = service.send(:extract_variants, Nokogiri::HTML(invalid_html))

      expect(groups).to eq(
        [
          {
            type: "size",
            data: [
              {
                size: "30x30 cm",
                item: { sku: "10614372", small_desc_name: "30x30 cm", images: [] }
              }
            ]
          }
        ]
      )
    end
  end
end
