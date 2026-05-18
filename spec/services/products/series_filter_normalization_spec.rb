# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::SeriesFilterNormalization do
  describe ".display_name" do
    it "strips Серия prefix" do
      expect(described_class.display_name("Серия NYMÅNE")).to eq("NYMÅNE")
      expect(described_class.display_name("Серия для гостиных HAUGA")).to eq("HAUGA")
    end
  end

  describe ".normalize_key" do
    it "dedupes synonyms to the same key" do
      expect(described_class.normalize_key("Серия TRÅDFRI")).to eq("TRADFRI")
      expect(described_class.normalize_key("TRÅDFRI")).to eq("TRADFRI")
    end
  end
end
