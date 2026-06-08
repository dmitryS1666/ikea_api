require "rails_helper"

RSpec.describe OrderItemSerializer do
  describe "image_url" do
    it "expands ActiveStorage refs stored on order item snapshots into public URLs" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("fake image content"),
        filename: "prod_img_#{'a' * 40}.webp",
        content_type: "image/webp"
      )

      order_item = build_stubbed(:order_item)
      order_item.define_singleton_method(:image_url) do
        [ProductLocalImages.encode_ref(blob)].to_json
      end

      image_url = described_class.new(order_item).serializable_hash.dig(:data, :attributes, :image_url)

      expect(image_url).to be_present
      expect(image_url).to start_with("/")
      expect(image_url).not_to include("as:")
      expect(image_url).not_to start_with("[")
    end

    it "falls back to first product local image before remote images" do
      product = build_stubbed(
        :product,
        local_images: ["/images/products/local.webp"],
        images: ["https://www.ikea.com/remote.jpg"]
      )
      order_item = build_stubbed(:order_item, product: product)

      image_url = described_class.new(order_item).serializable_hash.dig(:data, :attributes, :image_url)

      expect(image_url).to eq("/images/products/local.webp")
    end
  end
end
