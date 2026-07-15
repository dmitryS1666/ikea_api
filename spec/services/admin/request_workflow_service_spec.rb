# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::RequestWorkflowService do
  let(:manager) { create(:user, role: "manager_requests") }
  let(:assignee) { create(:user, role: "site_admin") }
  let(:order) { create(:order) }

  around do |example|
    Current.set(admin_user: manager, request_id: "request-1", ip_address: "127.0.0.1") do
      example.run
    end
  ensure
    Current.reset
  end

  it "adds a manager comment and records assignment and status history" do
    described_class.add_comment!(record: order, actor: manager, body: "  Позвонить клиенту  ")
    order.update!(assigned_to: assignee)
    order.update!(status: :processing)

    expect(order.request_activities.comments.last).to have_attributes(
      actor: manager,
      body: "Позвонить клиенту"
    )
    expect(order.request_activities.where(activity_type: "assigned").last.assignee).to eq(assignee)
    expect(order.request_activities.where(activity_type: "status_changed").last).to have_attributes(
      from_status: "created",
      to_status: "processing"
    )
  end

  it "rejects an empty comment" do
    expect do
      described_class.add_comment!(record: order, actor: manager, body: " ")
    end.to raise_error(ArgumentError, /не может быть пустым/)
  end
end
