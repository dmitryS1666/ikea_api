# frozen_string_literal: true

require "rails_helper"

RSpec.describe RequestActivity, type: :model do
  it "requires text for a manager comment" do
    activity = described_class.new(
      trackable: create(:order),
      activity_type: "comment",
      body: " "
    )

    expect(activity).not_to be_valid
    expect(activity.errors[:body]).to be_present
  end
end
