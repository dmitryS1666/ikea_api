require "rails_helper"

RSpec.describe CartSelectionService do
  let(:user) { create(:user) }
  let(:cart) { create(:cart, user: user) }
  let!(:product_a) { create(:product, sku: "SKU-A", quantity: 10, price: 50.0) }
  let!(:product_b) { create(:product, sku: "SKU-B", quantity: 10, price: 80.0) }

  before do
    create(:cart_item, cart: cart, product_sku: "SKU-A", quantity: 3)
    create(:cart_item, cart: cart, product_sku: "SKU-B", quantity: 1)
  end

  describe ".build_subset_cart" do
    it "caps quantity to cart stock" do
      selections = [
        described_class::ItemSelection.new(sku: "SKU-A", quantity: 10),
        described_class::ItemSelection.new(sku: "SKU-B", quantity: 1)
      ]

      result = described_class.build_subset_cart(cart: cart, selections: selections)
      expect(result[:error]).to be_nil
      expect(result[:cart].cart_items.find { |i| i.product_sku == "SKU-A" }.quantity).to eq(3)
      expect(result[:cart].cart_items.find { |i| i.product_sku == "SKU-B" }.quantity).to eq(1)
    end

    it "returns error for unknown sku" do
      selections = [described_class::ItemSelection.new(sku: "MISSING", quantity: 1)]
      result = described_class.build_subset_cart(cart: cart, selections: selections)
      expect(result[:code]).to eq("item_not_in_cart")
    end
  end

  describe ".consume_from_cart!" do
    it "leaves unselected quantities in cart" do
      selections = [described_class::ItemSelection.new(sku: "SKU-A", quantity: 1)]
      described_class.consume_from_cart!(cart: cart, selections: selections)

      expect(cart.cart_items.find_by(product_sku: "SKU-A").quantity).to eq(2)
      expect(cart.cart_items.find_by(product_sku: "SKU-B").quantity).to eq(1)
    end
  end
end
