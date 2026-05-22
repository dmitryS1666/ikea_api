# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlugifyService do
  describe ".call" do
    it "transliterates cyrillic" do
      expect(described_class.call("Стул белый")).to eq("stul-belyy")
    end

    it "strips scandinavian diacritics" do
      expect(described_class.call("RÖNNINGE")).to eq("ronninge")
      expect(described_class.call("Lyngör")).to eq("lyngor")
    end

    it "collapses non-alphanumeric runs to a single hyphen" do
      expect(described_class.call("  foo--bar!! ")).to eq("foo-bar")
    end
  end
end
