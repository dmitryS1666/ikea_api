require "rails_helper"

RSpec.describe OrderServicesFormatter do
  describe ".label" do
    it "returns Russian label for known service codes" do
      expect(described_class.label("furniture_delivery")).to eq("Доставка мебели")
      expect(described_class.label("furniture_assembly")).to eq("Сборка мебели")
    end

    it "falls back to the code for unknown services" do
      expect(described_class.label("unknown_service")).to eq("unknown_service")
    end
  end

  describe ".labels_joined" do
    it "joins multiple services in Russian" do
      expect(
        described_class.labels_joined(%w[furniture_delivery furniture_assembly])
      ).to eq("Доставка мебели, Сборка мебели")
    end
  end
end
