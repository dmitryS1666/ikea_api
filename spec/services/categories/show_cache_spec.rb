# frozen_string_literal: true

require "rails_helper"

RSpec.describe Categories::ShowCache do
  let(:category) { create(:category, ikea_id: "700403", name: "Storage", translated_name: "Хранение") }
  let(:city) { "minsk" }
  let(:site_url) { "https://ikeya.by" }

  around do |example|
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = previous_cache
  end

  before do
    allow(ExchangeRate).to receive(:fetch_or_create).with("PLN").and_return(
      instance_double(ExchangeRate, rate_per_unit: 0.3)
    )
    allow(CalculatorSetting).to receive(:get).with("exchange_rate_buffer").and_return(1.05)
  end

  describe ".fetch" do
    it "returns nil for missing category" do
      expect(described_class.fetch(ikea_id: "missing", city: city, site_url: site_url)).to be_nil
    end

    it "serializes category and serves subsequent reads from cache" do
      category

      expect(CategorySerializer).to receive(:new).once.and_call_original

      first = described_class.fetch(ikea_id: category.ikea_id, city: city, site_url: site_url)
      second = described_class.fetch(ikea_id: category.ikea_id, city: city, site_url: site_url)

      expect(first.dig(:data, :id)).to eq(category.ikea_id)
      expect(second).to eq(first)
    end
  end

  describe ".bust!" do
    it "removes cached payload for the category" do
      category
      described_class.fetch(ikea_id: category.ikea_id, city: city, site_url: site_url)

      described_class.bust!(category.ikea_id)

      expect(CategorySerializer).to receive(:new).once.and_call_original
      described_class.fetch(ikea_id: category.ikea_id, city: city, site_url: site_url)
    end
  end
end
