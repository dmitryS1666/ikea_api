# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::CategoryRelatedProductsHarvestService do
  describe ".call" do
    let(:category) { Category.create!(ikea_id: "999991", name: "Test leaf") }

    it "upserts list from first and last listing rows using PlDetailsFetcher" do
      row_first = { "id" => "s11111111", "pipUrl" => "/pl/pl/p/a-s11111111/" }
      row_mid = { "id" => "s22222222", "pipUrl" => "/pl/pl/p/b-s22222222/" }
      row_last = { "id" => "s33333333", "pipUrl" => "/pl/pl/p/c-s33333333/" }

      allow(PlDetailsFetcher).to receive(:related_skus_bundle_for_product_url)
        .with("https://www.ikea.com/pl/pl/p/a-s11111111/", scope_sku: "s11111111")
        .and_return(%w[44444444 55555555])
      allow(PlDetailsFetcher).to receive(:related_skus_bundle_for_product_url)
        .with("https://www.ikea.com/pl/pl/p/c-s33333333/", scope_sku: "s33333333")
        .and_return(%w[55555555 66666666])

      described_class.call(category: category, listing_rows: [row_first, row_mid, row_last])

      list = CategoryRelatedProductList.find_by!(category_id: "999991")
      expect(list.related_products).to contain_exactly("44444444", "55555555", "66666666")
      expect(list.anchor_first_sku).to eq("s11111111")
      expect(list.anchor_last_sku).to eq("s33333333")
    end

    it "uses a single anchor when listing has one row" do
      row = { "id" => "60580273", "url" => "/pl/pl/p/x-60580273/" }
      allow(PlDetailsFetcher).to receive(:related_skus_bundle_for_product_url)
        .and_return(%w[77777777])

      described_class.call(category: category, listing_rows: [row])

      list = CategoryRelatedProductList.find_by!(category_id: "999991")
      expect(list.related_products).to eq(%w[77777777])
      expect(list.anchor_last_sku).to be_nil
    end

    it "merges product accessories into existing category related list" do
      CategoryRelatedProductList.create!(
        category_id: category.ikea_id,
        related_products: %w[11111111 22222222]
      )

      described_class.merge_skus!(
        category: category,
        skus: %w[22222222 33333333 44444444],
        exclude_skus: %w[44444444],
        anchor_sku: "99999999"
      )

      list = CategoryRelatedProductList.find_by!(category_id: category.ikea_id)
      expect(list.related_products).to eq(%w[11111111 22222222 33333333])
    end
  end
end
