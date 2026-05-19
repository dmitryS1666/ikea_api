require 'rails_helper'

RSpec.describe PlDetailsFetcher do
  describe '.parse_html (PIPF секции без модального DOM)' do
    it 'extracts product info, dimensions and extended sections by headings' do
      html = File.read(Rails.root.join('spec/fixtures/files/ikea_pipf_sample.html'))

      result = described_class.parse_html(html, 'https://www.ikea.com/pl/pl/p/sample-70582542/', use_headless: false)

      # Basic
      expect(result[:name]).to eq('SKOENABAECK')
      expect(result[:sku]).to eq('70582542')

      # Product info section
      expect(result[:short_description]).to include('Ta sofa jest wygodna')
      expect(result[:description]).to include('Pokrowiec można łatwo zdjąć')

      # Materials & care (from section-based extraction in extract_modal_details)
      expect(result[:materials]).to include('Rama: Stal')
      expect(result[:materials]).to include('Tkanina: 100% poliester')
      expect(result[:care_instructions]).to include('Odkurzać regularnie')

      # Safety / good to know
      expect(result[:safety_info]).to include('Nie stawać na sofie')
      expect(result[:good_to_know]).to include('W zestawie komplet śrub')

      # Dimensions string should be derived by extract_packaging_info regex fallback
      expect(result[:dimensions]).to include('158')
      expect(result[:dimensions]).to include('75')
      expect(result[:dimensions]).to include('74')
    end

    it 'splits pipcom price module h1 into name and small_desc_name (overrides JSON-LD title)' do
      html = <<~HTML
        <!DOCTYPE html>
        <html><head>
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"HUMLESJÖN HUMLESJÖN - светло-зеленый 26x13x7 см","mpn":"30600958"}</script>
        </head><body>
        <h1 class="pipcom-text pipcom-typography-heading-s">
          <span class="pipcom-price-module__name-decorator notranslate">HUMLESJÖN HUMLESJÖN</span>
          <span class="pipcom-text pipcom-typography-label-l pipcom-price-module__description">
            <span>светло-зеленый, <a href="#" aria-label="26x13x7 см. Показать размеры">26x13x7 см</a></span>
          </span>
        </h1>
        </body></html>
      HTML

      result = described_class.parse_html(html, 'https://www.ikea.com/lt/ru/p/sample/', use_headless: false)

      expect(result[:name]).to eq('HUMLESJÖN HUMLESJÖN')
      expect(result[:name_ru]).to eq('HUMLESJÖN HUMLESJÖN')
      expect(result[:small_desc_name]).to eq('светло-зеленый, 26x13x7 см')
      expect(result[:sku]).to eq('30600958')
    end

    it 'scopes gallery images to scope_sku via data-item-no ancestors' do
      html = <<~HTML
        <!DOCTYPE html><html><body>
        <div class="pipf-product-gallery">
          <div data-item-no="s11111111">
            <img src="https://www.ikea.com/pl/pl/images/products/other__11111111_pe000001_s5.jpg" alt="" />
          </div>
          <div data-item-no="s29537086">
            <img src="https://www.ikea.com/pl/pl/images/products/ok__29537086_pe000002_s5.jpg" alt="" />
            <img data-src="https://www.ikea.com/pl/pl/images/products/ok__29537086_pe000003_s5.jpg" alt="" />
          </div>
        </div>
        </body></html>
      HTML

      scoped = described_class.parse_html(html, "https://www.ikea.com/pl/pl/p/x-s29537086/", use_headless: false, scope_sku: "s29537086")
      expect(scoped[:images].map { |u| File.basename(u) }).to contain_exactly(
        "ok__29537086_pe000002_s5.jpg",
        "ok__29537086_pe000003_s5.jpg"
      )

      unscoped = described_class.parse_html(html, "https://www.ikea.com/pl/pl/p/x-s29537086/", use_headless: false)
      expect(unscoped[:images].length).to eq(3)
    end

    it "sets included_sheet_needs_headless when package sheet is clickable but modal is absent" do
      html = <<~HTML
        <!DOCTYPE html><html><body>
          <button class="pipf-list-view-item__action">Elementy w zestawie</button>
        </body></html>
      HTML

      result = described_class.parse_html(html, "https://www.ikea.com/pl/pl/p/x-s29545213/", use_headless: false)

      expect(result[:included_sheet_needs_headless]).to eq(true)
      expect(result[:included_products]).to be_nil
    end

    it "extracts included_products from pipf-included-products-modal when present in HTML" do
      html = <<~HTML
        <!DOCTYPE html><html><body>
          <div class="pipf-included-products-modal">
            <ul class="pipf-included-products-modal__list">
              <li><a href="https://www.ikea.com/pl/pl/p/foo-60489549/">a</a></li>
              <li><span class="pipf-product-identifier__value">004.176.21</span></li>
            </ul>
          </div>
        </body></html>
      HTML

      result = described_class.parse_html(html, "https://www.ikea.com/pl/pl/p/x-s29545213/", use_headless: false)

      expect(result[:included_products]).to contain_exactly("60489549", "00417621")
      expect(result[:included_products_from_modal]).to eq(true)
      expect(result[:included_sheet_needs_headless]).to eq(false)
    end

    it "extracts related_products only from accessories modal cards" do
      html = <<~HTML
        <!DOCTYPE html><html><body>
          <div class="pipf-upsell-modal">
            <div class="pipf-upsell" data-product-number="80598627"></div>
            <div class="pipf-upsell" data-product-number="40624384"></div>
            <a href="https://www.ikea.com/pl/pl/p/foo-bar-90304889/"></a>
          </div>
          <a href="https://www.ikea.com/pl/pl/p/should-not-be-related-99999999/"></a>
        </body></html>
      HTML

      result = described_class.parse_html(html, "https://www.ikea.com/pl/pl/p/x-s29537086/", use_headless: false)
      expect(result[:related_products]).to contain_exactly("80598627", "40624384", "90304889")
    end
  end
end
