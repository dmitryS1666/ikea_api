# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::VideoUrlExtractor do
  describe ".urls_from_product" do
    it "collects downloadable and embed urls from videos, images and full_attributes" do
      product = build(
        :product,
        videos: [
          "https://www.ikea.com/pvid/0823552_fe001096.mp4",
          { "url" => "https://www.youtube.com/embed/abc123" }
        ],
        images: [
          "https://www.ikea.com/pl/pl/images/products/foo.jpg",
          "https://www.ikea.com/pvid/preview.jpg"
        ],
        full_attributes: {
          "media" => [{ "src" => "https://www.ikea.com/global/assets/clip.webm" }]
        }
      )

      expect(described_class.urls_from_product(product)).to contain_exactly(
        "https://www.ikea.com/pvid/0823552_fe001096.mp4",
        "https://www.youtube.com/embed/abc123",
        "https://www.ikea.com/global/assets/clip.webm"
      )
    end
  end

  describe ".urls_from_html" do
    it "picks ikea pvid files and absolute video urls from raw html" do
      html = <<~HTML
        <video src="//www.ikea.com/pvid/111_fe0001.mp4"></video>
        <iframe src="https://player.vimeo.com/video/9"></iframe>
        <img src="https://www.ikea.com/pvid/111_fe0001.jpg">
      HTML

      expect(described_class.urls_from_html(html)).to contain_exactly(
        "https://www.ikea.com/pvid/111_fe0001.mp4",
        "https://player.vimeo.com/video/9"
      )
    end
  end

  describe ".classify" do
    it "marks youtube as embed and ikea mp4 as file" do
      expect(described_class.classify("https://youtu.be/x")).to eq(:embed)
      expect(described_class.classify("https://www.ikea.com/pvid/x.mp4")).to eq(:file)
      expect(described_class.classify("https://www.ikea.com/pvid/x.jpg")).to eq(:other)
    end
  end
end
