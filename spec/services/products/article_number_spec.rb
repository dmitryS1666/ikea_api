# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::ArticleNumber do
  describe ".normalize" do
    it "pads leading zeros for short numeric articles" do
      expect(described_class.normalize("417621")).to eq("00417621")
      expect(described_class.normalize("004.176.21")).to eq("00417621")
    end

    it "keeps eight-digit articles" do
      expect(described_class.normalize("60489549")).to eq("60489549")
      expect(described_class.normalize("s60489549")).to eq("60489549")
    end
  end
end
