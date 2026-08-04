# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sitemaps::Builder do
  let(:settings) { instance_double(FeedSetting, base_url_root: "https://ikeya.by") }

  def locs(xml)
    Nokogiri::XML(xml).xpath("//xmlns:loc", "xmlns" => "http://www.sitemaps.org/schemas/sitemap/0.9").map(&:text)
  end

  it "includes static, catalog, product, seo, article and legal pages with storefront paths" do
    category = create(:category, ikea_id: "100", name: "Мебель", translated_name: "Мебель", parent_ids: [], cached_slug: "mebel")
    product = create(:product, sku: "s90205097", name: "KALLAX", cached_slug: "kallax", quantity: 5)
    create(:seo_catalog_page, :published, slug: "deshevye-stoly", products_count: 3, indexable: true)
    create(:content_article, title: "Идея", slug: "ideya", status: :published, active: true)
    LegalPage.create!(title: "Политика", slug: "privacy-policy-test", body: "x", status: :published)

    xml = described_class.call(settings: settings)
    urls = locs(xml)

    expect(urls).to include("https://ikeya.by/")
    expect(urls).to include("https://ikeya.by/catalog/")
    expect(urls).to include("https://ikeya.by/about/")
    expect(urls).to include("https://ikeya.by/help/delivery/")
    expect(urls).to include("https://ikeya.by/catalog/mebel/")
    expect(urls).to include("https://ikeya.by/product/kallax-90205097/")
    expect(urls).to include("https://ikeya.by/catalog/deshevye-stoly/")
    expect(urls).to include("https://ikeya.by/blog/ideya/")
    expect(urls).to include("https://ikeya.by/help/privacy-policy-test/")
    expect(urls).not_to include("https://ikeya.by/category/#{category.ikea_id}")
    expect(urls).not_to include("https://ikeya.by/product/#{product.sku}")
  end

  it "skips out-of-stock products and non-indexable seo pages" do
    create(:product, sku: "s11111111", cached_slug: "gone", quantity: 0)
    create(:seo_catalog_page, :published, slug: "empty-page", products_count: 0, indexable: false)

    xml = described_class.call(settings: settings)
    urls = locs(xml)

    expect(urls).not_to include("https://ikeya.by/product/gone-11111111/")
    expect(urls).not_to include("https://ikeya.by/catalog/empty-page/")
  end
end
