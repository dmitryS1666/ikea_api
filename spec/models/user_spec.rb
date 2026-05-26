# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  describe ".normalize_gender" do
    it "maps lowercase and localized aliases to canonical values" do
      expect(described_class.normalize_gender("male")).to eq("Male")
      expect(described_class.normalize_gender("female")).to eq("Female")
      expect(described_class.normalize_gender("Мужской")).to eq("Male")
      expect(described_class.normalize_gender("женский")).to eq("Female")
    end

    it "keeps canonical values unchanged" do
      expect(described_class.normalize_gender("Male")).to eq("Male")
      expect(described_class.normalize_gender("Female")).to eq("Female")
    end
  end

  describe "#gender" do
    it "returns canonical value for legacy lowercase storage" do
      user = build(:user, gender: "male")
      user.write_attribute(:gender, "male")

      expect(user.gender).to eq("Male")
    end
  end
end
