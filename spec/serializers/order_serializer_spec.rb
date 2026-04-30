require "rails_helper"

RSpec.describe OrderSerializer do
  before do
    allow(CrmSyncJob).to receive(:perform_later)
    allow(OrderNotificationService).to receive(:call)
  end

  describe "status_description" do
    it "returns localized description for order status" do
      order = create(:order, status: "processing")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:status]).to eq("processing")
      expect(attrs[:status_description]).to eq("В работе")
    end
  end

  describe "status_timeline" do
    it "returns timeline with status timestamps and current marker" do
      order = create(:order, status: "created")
      order.update!(status: "paid")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]
      timeline = attrs[:status_timeline]
      created_row = timeline.find { |row| row[:code] == "created" }
      paid_row = timeline.find { |row| row[:code] == "paid" }
      processing_row = timeline.find { |row| row[:code] == "processing" }

      expect(timeline).to be_an(Array)
      expect(created_row[:at]).to be_present
      expect(created_row[:is_completed]).to be(true)
      expect(paid_row[:is_current]).to be(true)
      expect(paid_row[:at]).to be_present
      expect(processing_row[:at]).to be_nil
      expect(processing_row[:is_completed]).to be(false)
    end
  end
end
