# frozen_string_literal: true

require "rails_helper"

RSpec.describe "SeoCatalogPage admin workflow", type: :model do
  let(:filter_config_json) do
    <<~JSON.squish
      {
        "category_ids": ["fb001"],
        "max_price": 1000,
        "filters": {"f-colors": ["white"]},
        "only_available": true,
        "sort": "popular",
        "limit": 60
      }
    JSON
  end

  describe "draft creation from admin form" do
    it "saves a draft with slug and parsed filter_config" do
      page = SeoCatalogPage.new(
        title: "Диваны до 1000 BYN",
        slug: "admin-workflow-draft",
        h1: "Диваны до 1000 BYN",
        status: :draft,
        indexable: true,
        meta_title: "Диваны до 1000 BYN — купить с доставкой",
        meta_description: "Подборка диванов до 1000 BYN с доставкой в Беларусь."
      )
      page.filter_config_json_input = filter_config_json

      expect(page).to be_valid
      expect { page.save! }.not_to raise_error

      page.reload
      expect(page.canonical_path).to eq("/catalog/seo/admin-workflow-draft")
      expect(page.filter_config).to include("max_price" => 1000, "only_available" => true)
    end

    it "allows minimal draft with slug only" do
      page = SeoCatalogPage.new(slug: "admin-workflow-minimal", status: :draft)

      expect(page).to be_valid
      expect { page.save! }.not_to raise_error
    end
  end

  describe "publishing" do
    it "rejects publish without required SEO fields and filter_config" do
      page = SeoCatalogPage.new(slug: "admin-workflow-bad-publish", status: :published)

      expect(page).not_to be_valid
      expect(page.errors[:h1]).to be_present
      expect(page.errors[:meta_title]).to be_present
      expect(page.errors[:meta_description]).to be_present
      expect(page.errors[:filter_config]).to be_present
    end

    it "publishes when all required fields are present" do
      page = SeoCatalogPage.create!(
        slug: "admin-workflow-published",
        title: "Диваны до 1000 BYN",
        h1: "Диваны до 1000 BYN",
        meta_title: "Диваны до 1000 BYN — купить с доставкой",
        meta_description: "Подборка диванов до 1000 BYN с доставкой в Беларусь.",
        status: :draft,
        filter_config: {
          "only_available" => true,
          "sort" => "popular",
          "limit" => 60
        }
      )

      page.status = :published
      expect(page).to be_valid
      expect { page.save! }.not_to raise_error
      expect(page.published_at).to be_present
    end
  end

  describe "documented filter_config examples" do
    it "accepts cheapest sort from the price-range example" do
      page = SeoCatalogPage.new(slug: "admin-workflow-cheapest", status: :draft)
      page.filter_config_json_input = <<~JSON.squish
        {
          "category_ids": ["bm001"],
          "min_price": 200,
          "max_price": 1500,
          "only_available": true,
          "sort": "cheapest",
          "limit": 120
        }
      JSON

      expect(page).to be_valid
      expect(page.filter_config["sort"]).to eq("cheapest")
    end
  end
end
