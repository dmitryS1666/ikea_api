# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::ImageTagsBuilder do
  let(:product) do
    create(
      :product,
      name: "LYNGÖR",
      local_images: ["/images/products/test.webp"]
    )
  end

  before do
    GlobalSeoSetting.find_or_create_by!(target_type: "product") do |s|
      s.image_alt_template = "{{name}} фото {{index}}"
      s.image_title_template = "{{name}}"
    end
  end

  it "builds alt and title from global templates" do
    result = described_class.for_product(product, "minsk")

    expect(result.size).to eq(1)
    expect(result.first[:url]).to eq("/images/products/test.webp")
    expect(result.first[:alt]).to eq("LYNGÖR фото 1")
    expect(result.first[:title]).to eq("LYNGÖR")
  end

  it "uses manual overrides from seo_meta" do
    create(:seo_metum, seoable: product, image_alt: "Ручной alt", image_title: "Ручной title")

    result = described_class.for_product(product.reload, "minsk")

    expect(result.first[:alt]).to eq("Ручной alt")
    expect(result.first[:title]).to eq("Ручной title")
  end
end
