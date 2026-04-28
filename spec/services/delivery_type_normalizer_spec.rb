require "rails_helper"

RSpec.describe DeliveryTypeNormalizer do
  describe ".normalize" do
    it "maps pickup to europost_pickup" do
      expect(described_class.normalize("pickup")).to eq("europost_pickup")
    end

    it "keeps europost_pickup as is" do
      expect(described_class.normalize("europost_pickup")).to eq("europost_pickup")
    end

    it "keeps courier as is" do
      expect(described_class.normalize("courier")).to eq("courier")
    end

    it "keeps ikeya_delivery as is" do
      expect(described_class.normalize("ikeya_delivery")).to eq("ikeya_delivery")
    end

    it "normalizes case and spaces" do
      expect(described_class.normalize("  PICKUP  ")).to eq("europost_pickup")
    end
  end
end
