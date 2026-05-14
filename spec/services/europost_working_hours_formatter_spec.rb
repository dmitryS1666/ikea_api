# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostWorkingHoursFormatter do
  describe ".summary_for_payload" do
    it "prefers schedules when present" do
      office = {
        "schedules" => [
          { "work_time" => "9:00-15:00", "lunch_time" => "14:00-15:00", "is_working" => "1" }
        ],
        "working_hours" => "10:00-22:00",
        "break_hours" => "Без обеда"
      }

      expect(described_class.summary_for_payload(office)).to eq("9:00-15:00, 14:00-15:00")
    end

    it "falls back to working_hours and break_hours when schedules are empty" do
      office = {
        "schedules" => [],
        "working_hours" => "10:00-22:00",
        "break_hours" => "Без обеда"
      }

      expect(described_class.summary_for_payload(office)).to eq("10:00-22:00, Без обеда")
    end

    it "returns nil when no schedules, no working_hours, and no legacy info" do
      office = { "WarehouseId" => "1" }

      expect(described_class.summary_for_payload(office)).to be_nil
    end

    it "uses legacy Info fields when external hours are absent" do
      office = {
        "Info1" => "Режим работы: пн-вс 10-20",
        "Info2" => "Доп. информация"
      }

      expect(described_class.summary_for_payload(office)).to eq("Режим работы: пн-вс 10-20")
    end
  end

  describe ".structured_for_payload" do
    it "includes schedules, break_hours, and break object" do
      office = {
        "schedules" => [{ "work_time" => "9:00-15:00" }],
        "break_hours" => "Без обеда",
        "break" => { "time_from" => "14:00", "time_to" => "15:00" }
      }

      expect(described_class.structured_for_payload(office)).to eq(
        schedules: [{ "work_time" => "9:00-15:00" }],
        break_hours: "Без обеда",
        break: { "time_from" => "14:00", "time_to" => "15:00" }
      )
    end

    it "maps array breaks to :breaks" do
      office = { "breaks" => [{ "a" => 1 }] }

      expect(described_class.structured_for_payload(office)).to eq(breaks: [{ "a" => 1 }])
    end

    it "includes working_hours when schedules are empty but API sent a string" do
      office = {
        "schedules" => [],
        "working_hours" => "10:00-22:00",
        "break_hours" => "13:00-14:00"
      }

      expect(described_class.structured_for_payload(office)).to eq(
        break_hours: "13:00-14:00",
        working_hours: "10:00-22:00"
      )
    end
  end
end
