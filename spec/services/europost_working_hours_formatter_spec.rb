# frozen_string_literal: true

require "rails_helper"

RSpec.describe EuropostWorkingHoursFormatter do
  describe ".summary_for_payload" do
    it "uses only today's schedule row when iso_day_of_week matches" do
      travel_to(Time.zone.local(2026, 5, 14, 12, 0, 0)) do
        office = {
          "schedules" => [
            { "work_time" => "9:00-15:00", "lunch_time" => "14:00-15:00", "is_working" => "1", "iso_day_of_week" => 4 },
            { "work_time" => "10:00-20:00", "is_working" => "1", "iso_day_of_week" => 5 }
          ],
          "working_hours" => "10:00-22:00",
          "break_hours" => "Без обеда"
        }

        expect(described_class.summary_for_payload(office)).to eq("9:00-15:00, 14:00-15:00")
      end
    end

    it "falls back to API working_hours and break_hours when schedules exist but not for today" do
      travel_to(Time.zone.local(2026, 5, 14, 12, 0, 0)) do
        office = {
          "schedules" => [
            { "work_time" => "10:00-20:00", "is_working" => "1", "iso_day_of_week" => 5 }
          ],
          "working_hours" => "09:00-21:00",
          "break_hours" => "14:00-15:00"
        }

        expect(described_class.summary_for_payload(office)).to eq("09:00-21:00, 14:00-15:00")
      end
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
    it "includes schedules with weekday_short from iso_day_of_week" do
      office = {
        "schedules" => [
          { "work_time" => "9:00-15:00", "iso_day_of_week" => 1 },
          { "work_time" => "10:00-20:00", "lunch_time" => "13:00-14:00", "iso_day_of_week" => 7 }
        ],
        "break_hours" => "Без обеда",
        "break" => { "time_from" => "14:00", "time_to" => "15:00" }
      }

      result = described_class.structured_for_payload(office)
      expect(result[:schedules]).to eq(
        [
          { "work_time" => "9:00-15:00", "iso_day_of_week" => 1, "weekday_short" => "пн" },
          { "work_time" => "10:00-20:00", "lunch_time" => "13:00-14:00", "iso_day_of_week" => 7, "weekday_short" => "вск" }
        ]
      )
      expect(result[:break_hours]).to eq("Без обеда")
      expect(result[:break]).to eq({ "time_from" => "14:00", "time_to" => "15:00" })
    end

    it "omits weekday_short when iso_day_of_week is missing" do
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
