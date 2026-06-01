# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::PriceCalculatorService do
  describe ".parse_cart_lines" do
    it "parses sku and quantity" do
      p1 = create(:product, sku: "80598646", price: 19.99, weight: 0.46)
      p2 = create(:product, sku: "90205097", price: 10.0, weight: 1.0)

      result = described_class.parse_cart_lines("80598646 8\n90205097:2")
      expect(result.errors).to be_empty
      expect(result.lines.size).to eq(2)
      expect(result.lines[0]).to include(sku: p1.sku, quantity: 8, product: p1)
      expect(result.lines[1]).to include(sku: p2.sku, quantity: 2, product: p2)
    end

    it "reports unknown sku" do
      allow(described_class).to receive(:find_product).and_return(nil)
      result = described_class.parse_cart_lines("missing-sku 1")
      expect(result.lines).to be_empty
      expect(result.errors.first).to include("не найден")
    end
  end

  describe ".calculate_sku" do
    let(:product) do
      create(
        :product,
        sku: "80598646",
        price: 20.0,
        weight: 0.46,
        delivery_cost: 5.0,
        full_attributes: {
          "measurements_modal" => {
            "packages" => [
              {
                "measurements" => [
                  { "name" => "Вес", "measure" => "0.46 кг" },
                  { "name" => "Упаковка(-и)", "measure" => "1" }
                ]
              }
            ]
          }
        }
      )
    end

    before do
      allow(ExchangeRate).to receive(:fetch_or_create).with("PLN", anything).and_return(double(rate_per_unit: 1.0))
      allow(ExchangeRate).to receive(:fetch_or_create).with("EUR", anything).and_return(double(rate_per_unit: 3.0))
    end

    it "calculates line for quantity" do
      result = described_class.calculate_sku(product, quantity: 3, date: Date.current)
      expect(result[:error]).to be_nil
      expect(result[:quantity]).to eq(3)
      expect(result[:line_weight_kg]).to eq(1.38)
      expect(result[:byn][:total_byn]).to be_positive
    end
  end
end
