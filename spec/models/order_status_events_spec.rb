require "rails_helper"

RSpec.describe "Order status events", type: :model do
  before do
    allow(CrmSyncJob).to receive(:perform_later)
    allow(OrderNotificationService).to receive(:call)
  end

  it "creates initial status event on order create" do
    order = create(:order, status: "created")

    expect(order.order_status_events.count).to eq(1)
    event = order.order_status_events.first
    expect(event.from_status).to be_nil
    expect(event.to_status).to eq("created")
    expect(event.source).to eq("system")
    expect(event.changed_at).to be_present
  end

  it "creates status transition event with explicit metadata" do
    order = create(:order, status: "created")

    freeze_time do
      changed_at = 2.hours.ago
      order.status_changed_at = changed_at
      order.status_change_source = "amo_webhook"
      order.status_change_raw_payload = { "updated_at" => changed_at.to_i, "status_id" => Order.statuses["paid"] }
      order.update!(status: "paid")

      event = order.order_status_events.order(:created_at).last
      expect(event.from_status).to eq("created")
      expect(event.to_status).to eq("paid")
      expect(event.source).to eq("amo_webhook")
      expect(event.changed_at.to_i).to eq(changed_at.to_i)
      expect(event.raw_payload).to include("updated_at" => changed_at.to_i)
    end
  end
end
