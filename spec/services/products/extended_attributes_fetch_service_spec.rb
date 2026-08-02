# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ExtendedAttributesFetchService do
  describe "#pl_product_url" do
    let(:service) { described_class.new }

    it "keeps leading s for IKEA set/combo SKU URLs" do
      product = build(:product, sku: "s29545213", item_no: "29545213")

      expect(service.send(:pl_product_url, product)).to eq("https://www.ikea.com/pl/pl/p/-s29545213/")
    end

    it "uses leading s from original IKEA URL when DB SKU lost it" do
      product = build(
        :product,
        sku: "29545213",
        item_no: "29545213",
        url: "https://www.ikea.com/lt/ru/p/vimle-3-mestnyy-divan-krovat-s-kozetkoy-s-shirokimi-podlokotnikami-gunnared-bezhevyy-s29545213/"
      )

      expect(service.send(:pl_product_url, product)).to eq("https://www.ikea.com/pl/pl/p/-s29545213/")
    end

    it "uses plain item number for a bundle component alias" do
      product = build(:product, sku: "s60489549", item_no: "60489549")
      service.instance_variable_set(:@bundle_component, true)

      expect(service.send(:pl_product_url, product)).to eq("https://www.ikea.com/pl/pl/p/-60489549/")
    end

    it "uses a plain article from the original component URL even if DB SKU has an s alias" do
      product = build(
        :product,
        sku: "s60489549",
        item_no: "60489549",
        url: "https://www.ikea.com/lt/ru/p/component-name-60489549/"
      )

      expect(service.send(:pl_product_url, product)).to eq("https://www.ikea.com/pl/pl/p/-60489549/")
    end
  end

  describe "#fetch_details_with_optional_headless" do
    let(:service) { described_class.new }
    let(:url) { "https://www.ikea.com/pl/pl/p/x-s29545213/" }

    before do
      allow(service).to receive(:pl_headless_enabled?).and_return(true)
    end

    it "retries with headless when included sheet is clickable but included_products is empty" do
      light = {
        materials: "Rama: Stal",
        care_instructions: "Odkurzać",
        included_products: [],
        included_sheet_needs_headless: true
      }
      headless = light.merge(included_products: %w[60489549 00417621])

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: "s29545213").and_return(light)
      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: true, scope_sku: "s29545213").and_return(headless)

      result = service.send(:fetch_details_with_optional_headless, url, scope_sku: "s29545213")

      expect(result[:included_products]).to eq(%w[60489549 00417621])
      expect(result).not_to have_key(:included_sheet_needs_headless)
    end

    it "does not retry headless when included list came from modal in static HTML" do
      complete = {
        materials: "Rama: Stal",
        care_instructions: "Odkurzać",
        included_products: %w[60489549],
        included_sheet_needs_headless: true,
        included_products_from_modal: true
      }

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: nil).and_return(complete)
      expect(PlDetailsFetcher).not_to receive(:fetch).with(url, use_headless: true, scope_sku: nil)

      service.send(:fetch_details_with_optional_headless, url)
    end

    it "retries headless when sheet is clickable but included list is partial and not from modal" do
      light = {
        materials: "Rama: Stal",
        care_instructions: "Odkurzać",
        included_products: %w[10568638],
        included_sheet_needs_headless: true,
        included_products_from_modal: false
      }
      headless = light.merge(
        included_products: %w[60489549 00417621 30489490 80498114 10568638],
        included_products_from_modal: true
      )

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: nil).and_return(light)
      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: true, scope_sku: nil).and_return(headless)

      result = service.send(:fetch_details_with_optional_headless, url)

      expect(result[:included_products]).to eq(%w[60489549 00417621 30489490 80498114 10568638])
    end

    it "copies small_desc_name from pl_details in apply_pl_descriptive" do
      service = described_class.new
      attributes = {}
      pl_details = { small_desc_name: "Szafka z 5 półkami, beżowy/pomarańczowy" }

      service.send(:apply_pl_descriptive, pl_details, attributes)

      expect(attributes[:small_desc_name]).to eq("Szafka z 5 półkami, beżowy/pomarańczowy")
    end

    it "translates Polish material-and-care blocks in product_details_modal" do
      service = described_class.new
      modal = {
        "accordion_sections" => [
          {
            "id" => "material-and-care",
            "material_blocks" => [
              { "pairs" => [{ "term" => "Rama:", "definition" => "Stal" }] }
            ],
            "care_blocks" => [
              { "header" => "Pielęgnacja", "lines" => ["Odkurzać miękką szczotką"] }
            ]
          }
        ]
      }
      attributes = { full_attributes: { "product_details_modal" => modal } }

      translations = {
        "Rama:" => "Рама:",
        "Stal" => "Сталь",
        "Pielęgnacja" => "Уход",
        "Odkurzać miękką szczotką" => "Пылесосить мягкой щёткой"
      }
      allow(TranslationService).to receive(:needs_polish_to_russian_translation?).and_call_original
      allow(TranslationService).to receive(:translate) { |text, **_opts| translations[text] || text }

      service.send(:translate_polish_in_stored_product_details_modal!, attributes)
      service.send(:sync_materials_and_care_from_product_details_modal!, attributes)

      sec = attributes[:full_attributes]["product_details_modal"]["accordion_sections"].first
      expect(sec["material_blocks"].first["pairs"].first["definition"]).to eq("Сталь")
      expect(attributes[:materials]).to include("Сталь")
      expect(attributes[:care_instructions]).to include("щёткой")
    end

    it "translates Polish small_desc_name to Russian in attributes" do
      service = described_class.new
      product = build(:product, small_desc_name: nil)
      attributes = { small_desc_name: "Szafka z 5 półkami, beżowy/pomarańczowy" }

      allow(TranslationService).to receive(:needs_polish_to_russian_translation?).and_call_original
      allow(TranslationService).to receive(:translate)
        .with(attributes[:small_desc_name], context: "product_small_desc_name")
        .and_return("Шкаф с 5 полками, бежевый/оранжевый")

      service.send(:apply_russian_translations_for_polish_fields!, product, attributes)

      expect(attributes[:small_desc_name]).to eq("Шкаф с 5 полками, бежевый/оранжевый")
    end

    it "retries with headless when materials are missing" do
      incomplete = { materials: nil, care_instructions: "Odkurzać", included_sheet_needs_headless: false }
      headless = { materials: "Rama", care_instructions: "Odkurzać" }

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: nil).and_return(incomplete)
      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: true, scope_sku: nil).and_return(headless)

      result = service.send(:fetch_details_with_optional_headless, url)

      expect(result[:materials]).to eq("Rama")
    end

    it "rotates to another headless attempt after a timeout or proxy block" do
      light = { materials: nil, care_instructions: "Odkurzać" }
      complete = { materials: "Rama", care_instructions: "Odkurzać" }
      attempts = 0

      allow(service).to receive(:sleep)
      allow(PlDetailsFetcher).to receive(:fetch)
        .with(url, use_headless: false, scope_sku: nil)
        .and_return(light)
      allow(PlDetailsFetcher).to receive(:fetch)
        .with(url, use_headless: true, scope_sku: nil) do
          attempts += 1
          raise PlDetailsFetcher::HeadlessFetchError, "HTTP 403" if attempts < 3

          complete
        end

      result = service.send(:fetch_details_with_optional_headless, url)

      expect(attempts).to eq(3)
      expect(service).to have_received(:sleep).with(1).once
      expect(service).to have_received(:sleep).with(2).once
      expect(result[:materials]).to eq("Rama")
    end
  end

  describe "price protection" do
    let(:service) { described_class.new }

    it "does not overwrite a valid stored price with zero from an incomplete card" do
      attributes = { price: 199 }

      service.send(:assign_valid_pl_price!, { price: 0 }, attributes)

      expect(attributes[:price]).to eq(199)
    end

    it "accepts a valid IKEA sale price" do
      attributes = {}

      service.send(:assign_valid_pl_price!, { price: "3798" }, attributes)

      expect(attributes[:price]).to eq("3798")
    end
  end
end
