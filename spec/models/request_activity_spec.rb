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

  it "exposes activity_type predicates used by the admin workflow UI" do
    comment = described_class.new(activity_type: "comment")
    status_changed = described_class.new(activity_type: "status_changed")
    assigned = described_class.new(activity_type: "assigned")
    created = described_class.new(activity_type: "created")

    expect(comment).to be_comment
    expect(status_changed).to be_status_changed
    expect(assigned).to be_assigned
    expect(created).to be_created

    expect(comment).not_to be_status_changed
    expect(comment).not_to be_assigned
  end
end
