# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::VariantProductsPreloader do
  it "loads variant records referenced by both variants and variants_payload" do
    sibling_from_column = create(:product, sku: "30583384")
    sibling_from_payload = create(:product, sku: "50583397")
    product = create(
      :product,
      sku: "00583385",
      variants: [sibling_from_column.sku],
      variants_payload: JSON.generate([{
        type: "color",
        data: [{
          item: { sku: sibling_from_payload.sku },
          color: "бежевый"
        }]
      }])
    )

    lookup = described_class.call([product])

    expect(lookup["00583385"]).to eq(product)
    expect(lookup["30583384"]).to eq(sibling_from_column)
    expect(lookup["50583397"]).to eq(sibling_from_payload)
  end

  it "ignores a malformed variants payload" do
    product = create(:product, sku: "00583385", variants_payload: "{broken")

    expect { described_class.call([product]) }.not_to raise_error
    expect(described_class.call([product])["00583385"]).to eq(product)
  end
end
