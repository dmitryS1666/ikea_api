# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserPassportService do
  describe ".profile_attributes" do
    it "extracts profile fields from passport payload" do
      passport = {
        first_name: "Иван",
        last_name: "Иванов",
        middle_name: "Иванович",
        dob: "1990-01-01",
        passport_number: "MP1234567"
      }

      expect(described_class.profile_attributes(passport)).to eq(
        first_name: "Иван",
        last_name: "Иванов",
        middle_name: "Иванович",
        dob: "1990-01-01"
      )
    end

    it "supports legacy birth date aliases" do
      passport = {
        first_name: "Мария",
        date_of_birth: "1985-05-10"
      }

      expect(described_class.profile_attributes(passport)).to eq(
        first_name: "Мария",
        dob: "1985-05-10"
      )
    end
  end

  describe ".with_profile_fields" do
    let(:user) do
      create(
        :user,
        first_name: "Анна",
        last_name: "Павлова",
        middle_name: "Сергеевна",
        dob: Date.parse("1992-12-01")
      )
    end

    it "returns passport hash with actual profile data overlaid" do
      passport = {
        "first_name" => "СтароеИмя",
        "last_name" => "СтараяФамилия",
        "middle_name" => "СтароеОтчество",
        "dob" => "2001-01-01",
        "passport_number" => "MP7654321"
      }

      expect(described_class.with_profile_fields(user: user, passport_hash: passport)).to include(
        "first_name" => "Анна",
        "last_name" => "Павлова",
        "middle_name" => "Сергеевна",
        "dob" => "1992-12-01",
        "passport_number" => "MP7654321"
      )
    end

    it "returns nil for blank passport payload" do
      expect(described_class.with_profile_fields(user: user, passport_hash: nil)).to be_nil
      expect(described_class.with_profile_fields(user: user, passport_hash: {})).to be_nil
    end
  end
end
