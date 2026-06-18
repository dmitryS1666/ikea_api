require "rails_helper"

RSpec.describe DeliveryTrackingService do
  describe ".call" do
    it "requests Europost tracking for courier delivery type" do
      order = instance_double(
        Order,
        track_number: "BY080059185809",
        delivery_type: DeliveryTypeNormalizer::COURIER
      )
      info = { status: "В пути", provider: "Европочта", tracking_url: "https://evropochta.by/tracking/?number=BY080059185809" }

      allow(EuropostTracker).to receive(:track).with("BY080059185809").and_return(info)
      allow(order).to receive(:update_columns)

      result = described_class.call(order)

      expect(result).to eq(info)
      expect(EuropostTracker).to have_received(:track).with("BY080059185809")
      expect(order).to have_received(:update_columns).with(tracking_info: info)
    end

    it "does not use Europost tracker for ikeya delivery" do
      order = instance_double(
        Order,
        track_number: "IK123",
        delivery_type: DeliveryTypeNormalizer::IKEYA_DELIVERY
      )

      allow(EuropostTracker).to receive(:track)
      allow(order).to receive(:update_columns)

      result = described_class.call(order)

      expect(result).to include(status: "Информация об отслеживании недоступна", provider: DeliveryTypeNormalizer::IKEYA_DELIVERY)
      expect(EuropostTracker).not_to have_received(:track)
      expect(order).to have_received(:update_columns).with(tracking_info: result)
    end
  end
end
