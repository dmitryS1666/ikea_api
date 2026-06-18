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


    it "returns in_transit_pvz for shipped Europost pickup orders" do
      order = create(
        :order,
        status: "shipped",
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]
      timeline = attrs[:status_timeline]
      in_transit_row = timeline.find { |row| row[:code] == "in_transit_pvz" }

      expect(attrs[:status]).to eq("in_transit_pvz")
      expect(attrs[:status_description]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.in_transit_pvz"))
      expect(in_transit_row[:title]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.in_transit_pvz"))
      expect(in_transit_row[:is_current]).to be(true)
    end

    it "keeps shipped status for non-PVZ delivery orders" do
      order = create(:order, status: "shipped", delivery_type: DeliveryTypeNormalizer::COURIER)

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:status]).to eq("shipped")
      expect(attrs[:status_description]).to eq(I18n.t("activerecord.attributes.order.statuses.shipped"))
    end

    it "returns final completed status as delivered for frontend" do
      order = create(:order, status: "completed")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]
      timeline = attrs[:status_timeline]
      delivered_row = timeline.find { |row| row[:code] == "delivered" }

      expect(attrs[:status]).to eq("delivered")
      expect(attrs[:status_description]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.delivered"))
      expect(delivered_row[:title]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.delivered"))
      expect(delivered_row[:is_current]).to be(true)
      expect(timeline.none? { |row| row[:code] == "completed" }).to be(true)
      expect(timeline.none? { |row| row[:code] == "received" }).to be(true)
    end

    it "returns cancelled status as canceled for frontend" do
      order = create(:order, status: "cancelled")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]
      timeline = attrs[:status_timeline]
      canceled_row = timeline.find { |row| row[:code] == "canceled" }

      expect(attrs[:status]).to eq("canceled")
      expect(attrs[:status_description]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.canceled"))
      expect(canceled_row[:title]).to eq(I18n.t("activerecord.attributes.order.frontend_statuses.canceled"))
      expect(canceled_row[:is_current]).to be(true)
      expect(timeline.none? { |row| row[:code] == "cancelled" }).to be(true)
    end
  end
  describe "tracking fields" do
    let(:tracking_info) { { "europost_create" => { "status" => "created" } } }

    it "returns track number and tracking info from Belarus customs for Europost pickup orders" do
      order = create(
        :order,
        status: "customs_belarus",
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        track_number: "BY080027046773",
        tracking_info: tracking_info
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:track_number]).to eq("BY080027046773")
      expect(attrs[:tracking_info]).to eq(tracking_info)
    end

    it "keeps track number visible for later Europost pickup statuses" do
      order = create(
        :order,
        status: "shipped",
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        track_number: "BY080027046773",
        tracking_info: tracking_info
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:status]).to eq("in_transit_pvz")
      expect(attrs[:track_number]).to eq("BY080027046773")
      expect(attrs[:tracking_info]).to eq(tracking_info)
    end

    it "hides track number and tracking info before Belarus customs" do
      order = create(
        :order,
        status: "on_border",
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        track_number: "BY080027046773",
        tracking_info: tracking_info
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:track_number]).to be_nil
      expect(attrs[:tracking_info]).to be_nil
    end

    it "returns track number and tracking info for Europost courier orders" do
      order = create(
        :order,
        status: "handed_to_courier",
        delivery_type: DeliveryTypeNormalizer::COURIER,
        track_number: "BY080027046773",
        tracking_info: tracking_info
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:track_number]).to eq("BY080027046773")
      expect(attrs[:tracking_info]).to eq(tracking_info)
    end

    it "hides track number and tracking info for IKEYA delivery orders" do
      order = create(
        :order,
        status: "handed_to_courier_ikeya",
        delivery_type: DeliveryTypeNormalizer::IKEYA_DELIVERY,
        track_number: "BY080027046773",
        tracking_info: tracking_info
      )

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:track_number]).to be_nil
      expect(attrs[:tracking_info]).to be_nil
    end
  end

end
