# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminRolePermission, type: :model do
  it "seeds defaults for every admin panel role" do
    described_class.delete_all

    described_class.ensure_defaults!

    expect(described_class.pluck(:role)).to match_array(User::ADMIN_PANEL_ROLES)
    manager = described_class.find_by!(role: "manager_requests")
    expect(manager.permissions_hash[:orders_manage]).to be(true)
    expect(manager.permissions_hash[:content_manage]).to be(false)
  end

  it "returns stored permissions for a role" do
    described_class.ensure_defaults!
    record = described_class.find_by!(role: "observer")
    record.update!(permission_content_read: true)

    expect(described_class.permissions_for("observer")[:content_read]).to be(true)
    expect(described_class.permissions_for("observer")[:content_manage]).to be(false)
  end

  it "resets a role back to code defaults" do
    described_class.ensure_defaults!
    record = described_class.find_by!(role: "technician")
    record.update!(permission_manage_users: true)

    record.reset_to_defaults!

    expect(record.reload.permissions_hash[:manage_users]).to be(false)
    expect(record.permissions_hash[:technical_manage]).to be(true)
  end
end
