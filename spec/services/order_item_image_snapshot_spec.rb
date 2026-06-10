require "rails_helper"

RSpec.describe OrderItemImageSnapshot do
  describe ".for_product" do
    it "returns first local product image before remote images" do
      product = build_stubbed(
        :product,
        local_images: ["/images/products/local.webp"],
        images: ["https://www.ikea.com/remote.jpg"]
      )

      expect(described_class.for_product(product)).to eq("/images/products/local.webp")
    end

    it "falls back to first remote product image" do
      product = build_stubbed(
        :product,
        local_images: [],
        images: ["https://www.ikea.com/remote.jpg"]
      )

      expect(described_class.for_product(product)).to eq("https://www.ikea.com/remote.jpg")
    end
  end
end
