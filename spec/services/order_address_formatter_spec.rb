require "rails_helper"

RSpec.describe OrderAddressFormatter do
  describe ".display" do
    it "formats courier address from delivery snapshot" do
      order = build(
        :order,
        address_json: {
          "delivery" => {
            "type" => "courier",
            "address" => {
              "city" => "Минск",
              "street" => "Независимости",
              "house" => "10",
              "apartment" => "5"
            }
          }
        }
      )

      expect(described_class.display(order)).to eq("Минск, Независимости, д. 10, кв. 5")
    end

    it "formats legacy top-level address keys" do
      order = build(:order, address_json: { "city" => "Минск", "street" => "Main", "house" => "1" })

      expect(described_class.display(order)).to eq("Минск, Main, д. 1")
    end

    it "formats europost pickup point" do
      order = build(
        :order,
        address_json: {
          "delivery" => {
            "type" => "europost_pickup",
            "pickup_point" => {
              "name" => "Европочта №1",
              "city" => "Минск",
              "address" => "ул. Монтажников, 2"
            }
          }
        }
      )

      expect(described_class.display(order)).to eq("Европочта №1 — Минск, ул. Монтажников, 2")
    end

    it "returns nil when address_json has no delivery location" do
      order = build(:order, address_json: { "weight_kg" => 1.2 })

      expect(described_class.display(order)).to be_nil
    end
  end
end
