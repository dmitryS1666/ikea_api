# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostOfficePhone do
  describe ".for_office" do
    it "returns explicit phone field when API provides it" do
      office = { "phone" => "+375 (29) 123-45-67" }
      expect(described_class.for_office(office)).to eq("+375291234567")
    end

    it "extracts phone from Info text" do
      office = { "Info1" => "Режим работы 9-21, тел. +375 29 535-36-36" }
      expect(described_class.for_office(office)).to eq("+375295353636")
    end

    it "falls back to default carrier phone when no data in office" do
      expect(described_class.for_office({ "WarehouseId" => "1" })).to eq("+375295353636")
    end

    it "uses EUROPOST_PVZ_PHONE when set" do
      prev = ENV["EUROPOST_PVZ_PHONE"]
      ENV["EUROPOST_PVZ_PHONE"] = "+375 17 389-74-74"
      expect(described_class.for_office({})).to eq("+375173897474")
    ensure
      if prev
        ENV["EUROPOST_PVZ_PHONE"] = prev
      else
        ENV.delete("EUROPOST_PVZ_PHONE")
      end
    end

    it "returns nil when EUROPOST_PVZ_PHONE is none" do
      prev = ENV["EUROPOST_PVZ_PHONE"]
      ENV["EUROPOST_PVZ_PHONE"] = "none"
      expect(described_class.for_office({})).to be_nil
    ensure
      if prev
        ENV["EUROPOST_PVZ_PHONE"] = prev
      else
        ENV.delete("EUROPOST_PVZ_PHONE")
      end
    end
  end
end
