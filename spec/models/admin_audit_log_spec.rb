# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminAuditLog, type: :model do
  it "records administrator changes and filters personal attributes" do
    owner = create(:user, role: "admin")
    user = create(:user)

    Current.set(admin_user: owner, request_id: "req-123", ip_address: "127.0.0.1") do
      user.update!(role: "observer", email: "changed@example.com")
    end

    log = described_class.where(auditable: user, action: "update").last
    expect(log).to have_attributes(actor: owner, request_id: "req-123", ip_address: "127.0.0.1")
    expect(log.changeset["role"]).to eq(["user", "observer"])
    expect(log.changeset["email"]).to eq("[FILTERED]")
  ensure
    Current.reset
  end

  it "is immutable once persisted" do
    log = described_class.create!(action: "update", resource: "order")

    expect(log).to be_readonly
    expect { log.update!(action: "destroy") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
