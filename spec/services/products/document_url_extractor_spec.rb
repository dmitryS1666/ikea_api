# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::DocumentUrlExtractor do
  describe ".urls_from_product" do
    it "collects pdfs from manuals, assembly_documents and full_attributes" do
      product = build(
        :product,
        manuals: [{ "url" => "https://www.ikea.com/pl/pl/manuals/aa-111.pdf", "local_url" => "/documents/aa.pdf" }],
        assembly_documents: [
          { "title" => "Montaż", "url" => "https://www.ikea.com/pl/pl/assembly_instructions/bb-222.pdf" }
        ],
        videos: ["https://www.ikea.com/pvid/clip.mp4"],
        images: ["https://www.ikea.com/pl/pl/images/products/foo.jpg"],
        full_attributes: {
          "product_details_modal" => {
            "accordion_sections" => [
              { "document_groups" => [{ "links" => [{ "url" => "/assembly_instructions/cc-333.pdf" }] }] }
            ]
          }
        }
      )

      expect(described_class.urls_from_product(product)).to contain_exactly(
        "https://www.ikea.com/pl/pl/manuals/aa-111.pdf",
        "https://www.ikea.com/pl/pl/assembly_instructions/bb-222.pdf",
        "https://www.ikea.com/assembly_instructions/cc-333.pdf"
      )
    end
  end

  describe ".urls_from_html" do
    it "picks assembly instruction pdfs and ignores images" do
      html = <<~HTML
        <a href="https://www.ikea.com/pl/pl/assembly_instructions/hemnes.pdf">PDF</a>
        <a href="/assembly_instructions/billy.pdf">rel</a>
        <img src="https://www.ikea.com/pl/pl/images/products/foo.jpg">
        <a href="https://www.ikea.com/pvid/clip.mp4">video</a>
      HTML

      expect(described_class.urls_from_html(html)).to contain_exactly(
        "https://www.ikea.com/pl/pl/assembly_instructions/hemnes.pdf",
        "https://www.ikea.com/assembly_instructions/billy.pdf"
      )
    end
  end

  describe ".classify" do
    it "keeps ikea pdfs and drops local document paths" do
      expect(described_class.classify("https://www.ikea.com/pl/pl/assembly_instructions/x.pdf")).to eq(:file)
      expect(described_class.classify("/documents/local.pdf")).to eq(:other)
      expect(described_class.classify("https://www.ikea.com/pvid/x.mp4")).to eq(:other)
    end
  end
end
