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
      expect(attrs[:status_description]).to eq(
        I18n.t("activerecord.attributes.order.statuses.processing")
      )
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

    it "returns final completed status as received for frontend" do
      order = create(:order, status: "completed")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]
      timeline = attrs[:status_timeline]
      received_row = timeline.find { |row| row[:code] == "received" }

      expect(attrs[:status]).to eq("received")
      expect(attrs[:status_description]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.received"))
      expect(received_row[:title]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.received"))
      expect(received_row[:is_current]).to be(true)
      expect(timeline.none? { |row| row[:code] == "completed" }).to be(true)
    end
  end
  describe "tracking fields" do
    it "returns track number and tracking info" do
      order = create(
        :order,
        track_number: "BY080027046773",
        tracking_info: { "europost_create" => { "status" => "created" } }
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:track_number]).to eq("BY080027046773")
      expect(attrs[:tracking_info]).to eq("europost_create" => { "status" => "created" })
    end
  end

end
