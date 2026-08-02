# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParserControl, type: :model do
  describe ".new_background_task_type?" do
    it "accepts only task types registered for the new dropdown" do
      expect(described_class.new_background_task_type?("refresh_category_catalog")).to be(true)
      expect(described_class.new_background_task_type?("categories")).to be(false)
      expect(described_class.new_background_task_type?(nil)).to be(false)
    end
  end
end
