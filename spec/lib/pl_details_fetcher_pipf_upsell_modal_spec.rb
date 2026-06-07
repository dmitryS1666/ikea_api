require 'rails_helper'

RSpec.describe PlDetailsFetcher do
  describe '.parse_html related_products from pipf-upsell-modal' do
    it 'extracts nested accessories from pipf-upsell-modal markup' do
      html = <<~HTML
        <!DOCTYPE html><html><body>
          <div class="pipf-sheets__content-wrapper">
            <div class="pipf-modal-body pipf-upsell-modal__body">
              <div class="pipf-upsell-modal">
                <div class="pipf-upsell-modal__content-wrapper">
                  <div data-category="Пледы" class="pipf-upsell-modal__content">
                    <div class="pipf-upsell-modal__section">
                      <div class="pipf-upsell-modal__card">
                        <div data-product-number="90304889" data-product-type="ART" data-product-name="VITMOSSA" class="pipf-upsell">
                          <a href="https://www.ikea.com/lt/ru/p/vitmossa-pled-seryy-90304889/"></a>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div data-category="Декоративные подушки" class="pipf-upsell-modal__content">
                    <div class="pipf-upsell-modal__section">
                      <div class="pipf-upsell-modal__card">
                        <div data-product-number="80598627" data-product-type="ART" data-product-name="SANDMOTT" class="pipf-upsell">
                          <a href="https://www.ikea.com/lt/ru/p/sandmott-podushka-goluboy-yarko-krasnyy-80598627/"></a>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <a href="https://www.ikea.com/lt/ru/p/should-not-be-related-99999999/"></a>
        </body></html>
      HTML

      result = described_class.parse_html(
        html,
        'https://www.ikea.com/lt/ru/p/glostad-divan-knisa-temno-seryy-90589022/',
        use_headless: false
      )

      expect(result[:related_products]).to contain_exactly('90304889', '80598627')
    end
  end
end
