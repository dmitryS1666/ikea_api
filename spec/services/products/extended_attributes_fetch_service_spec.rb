# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ExtendedAttributesFetchService do
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

    it "does not retry headless when modal is complete and included_products are present" do
      complete = {
        materials: "Rama: Stal",
        care_instructions: "Odkurzać",
        included_products: %w[60489549],
        included_sheet_needs_headless: false
      }

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: nil).and_return(complete)
      expect(PlDetailsFetcher).not_to receive(:fetch).with(url, use_headless: true, scope_sku: nil)

      service.send(:fetch_details_with_optional_headless, url)
    end

    it "retries with headless when materials are missing" do
      incomplete = { materials: nil, care_instructions: "Odkurzać", included_sheet_needs_headless: false }
      headless = { materials: "Rama", care_instructions: "Odkurzać" }

      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: false, scope_sku: nil).and_return(incomplete)
      expect(PlDetailsFetcher).to receive(:fetch).with(url, use_headless: true, scope_sku: nil).and_return(headless)

      result = service.send(:fetch_details_with_optional_headless, url)

      expect(result[:materials]).to eq("Rama")
    end
  end
end
