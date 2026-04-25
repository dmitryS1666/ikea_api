require "rails_helper"

RSpec.describe OrderSerializer do
  describe "status_description" do
    it "returns localized description for order status" do
      order = create(:order, status: "processing")

      attrs = described_class.new(order).serializable_hash[:data][:attributes]

      expect(attrs[:status]).to eq("processing")
      expect(attrs[:status_description]).to eq("В работе")
    end
  end
end
