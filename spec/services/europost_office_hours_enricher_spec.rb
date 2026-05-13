# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostOfficeHoursEnricher do
  describe ".enrich" do
    let(:offices) do
      [
        {
          "WarehouseId" => "40130190",
          "WarehouseName" => "EP Office",
          "Address7Name" => "Гродно",
          "Info1" => "legacy"
        }
      ]
    end

    it "returns offices unchanged when EUROPOST_API_TOKEN is blank" do
      prev = ENV["EUROPOST_API_TOKEN"]
      ENV.delete("EUROPOST_API_TOKEN")
      expect(described_class.enrich(offices, type: nil)).to eq(offices)
    ensure
      if prev
        ENV["EUROPOST_API_TOKEN"] = prev
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end

    it "merges external store rows matched by WarehouseId" do
      store = {
        "id" => 40_130_190,
        "working_hours" => "10:00-22:00",
        "break_hours" => "Без обеда",
        "schedules" => [{ "work_time" => "9:00-15:00", "lunch_time" => "14:00-15:00" }],
        "break" => { "time_from" => "14:00", "time_to" => "14:10" },
        "ops_number" => 777
      }

      prev = ENV["EUROPOST_API_TOKEN"]
      ENV["EUROPOST_API_TOKEN"] = "secret-token"
      allow(EuropostApiService).to receive(:external_stores).with(type: 1).and_return([store])

      merged = described_class.enrich(offices, type: 1).first

      expect(merged["working_hours"]).to eq("10:00-22:00")
      expect(merged["schedules"].size).to eq(1)
      expect(merged["ops_number"]).to eq(777)
      expect(merged["WarehouseId"]).to eq("40130190")
    ensure
      if prev
        ENV["EUROPOST_API_TOKEN"] = prev
      else
        ENV.delete("EUROPOST_API_TOKEN")
      end
    end
  end
end
