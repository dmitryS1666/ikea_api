require "rails_helper"
require "stringio"

RSpec.describe ContentArticle, type: :model do
  around do |example|
    original_host = Rails.application.routes.default_url_options[:host]
    Rails.application.routes.default_url_options[:host] = "http://test.host"
    example.run
    Rails.application.routes.default_url_options[:host] = original_host
  end

  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("fake-image"),
      filename: "hero.png",
      content_type: "image/png"
    )
  end

  describe "body block template text_button_wide_image" do
    it "normalizes to hero slot, button fields, and no slider SKUs" do
      article = build(:content_article)
      article.body_blocks = [
        {
          "type" => "text_button_wide_image",
          "content" => "<p>Intro</p>",
          "button_text" => "В каталог",
          "button_category_id" => "12345",
          "images" => [{ "slot" => "hero_image", "signed_id" => nil }]
        }
      ]
      article.valid?
      block = article.body_blocks.first
      expect(block["type"]).to eq("text_button_wide_image")
      expect(block["button_enabled"]).to eq(true)
      expect(block["slider_enabled"]).to eq(false)
      expect(block["slider_product_skus"]).to eq([])
      expect(block["images"].map { |i| i["slot"] }).to eq(["hero_image"])
      expect(block["button_text"]).to eq("В каталог")
      expect(block["button_category_id"]).to eq("12345")
    end
  end

  describe "validate_body_block_products" do
    let(:products_grid_block) do
      {
        "type" => "products_grid",
        "content" => "",
        "slider_product_skus" => %w[NO-SUCH-SKU]
      }
    end

    it "does not block draft saves when SKUs are missing from catalog" do
      article = build(:content_article, content_type: :news, status: :draft, body_blocks: [products_grid_block])
      expect(article).to be_valid
      expect(article.save).to eq(true)
    end

    it "rejects published articles with unknown SKUs in product grid blocks" do
      article = build(:content_article, content_type: :news, status: :published, body_blocks: [products_grid_block])
      expect(article).not_to be_valid
      expect(article.errors[:body_blocks].join).to include("NO-SUCH-SKU")
    end
  end

  describe "publication visibility" do
    it "keeps published articles active so Published status appears on the site" do
      article = build(:content_article, status: :published, active: false)

      article.valid?

      expect(article.active).to eq(true)
    end
  end

  describe "body block uploads" do
    it "attaches referenced block images" do
      template = ContentArticle::BODY_BLOCK_TEMPLATES.first
      slot_name = template[:image_slots].first[:name]
      article = build(:content_article)
      article.body_blocks = [
        {
          "type" => template[:id],
          "content" => "<p>Описание</p>",
          "images" => [
            { "slot" => slot_name, "signed_id" => blob.signed_id }
          ]
        }
      ]

      article.save!

      attached_ids = article.body_block_images.map(&:signed_id)
      expect(attached_ids).to include(blob.signed_id)
    end
  end

  describe "serializer body blocks" do
    it "exposes image urls and button category data" do
      template = ContentArticle::BODY_BLOCK_TEMPLATES.find { |tpl| tpl[:button_enabled] }
      slot_name = template[:image_slots].first[:name]
      category = create(:category, ikea_id: "123", name: "Гостиная")

      article = create(:content_article, body_blocks: [
        {
          "type" => template[:id],
          "content" => "<p>Слайдер</p>",
          "button_text" => "Вдохновение",
          "button_category_id" => category.ikea_id,
          "images" => [
            { "slot" => slot_name, "signed_id" => blob.signed_id }
          ]
        }
      ])

      serialized = ContentArticleSerializer.new(article).serializable_hash
      serialized_blocks = serialized[:data][:attributes][:body_blocks]

      expect(serialized_blocks.length).to eq(1)
      expect(serialized_blocks.first["images"].first["url"]).to include("/rails/active_storage/blobs")
      expect(serialized_blocks.first["button_category"]["ikea_id"]).to eq(category.ikea_id)
      expect(serialized_blocks.first["button_category"]["name"]).to eq(category.name)
      expect(serialized_blocks.first["button_category"]["slug"]).to eq(category.slug)
      expect(serialized_blocks.first["button_category"]["url"]).to eq(category.catalog_url)
    end

    it "exposes slug and catalog url for slider category" do
      category = create(:category, ikea_id: "bm001", name: "Łóżka i materace", cached_slug: "budilniki")

      article = create(:content_article, body_blocks: [
        {
          "type" => "image_left_text_right",
          "content" => "<p>Текст</p>",
          "slider_category_id" => category.ikea_id
        }
      ])

      block = ContentArticleSerializer.new(article).serializable_hash[:data][:attributes][:body_blocks].first

      expect(block["slider_category"]).to eq(
        "ikea_id" => "bm001",
        "name" => "Łóżka i materace",
        "slug" => "budilniki",
        "url" => "/catalog/budilniki/"
      )
    end

    it "exposes admin HTML and product grid payloads for frontend rendering" do
      product = create(:product, sku: "GRID-SKU", name: "Grid product")
      article = create(:content_article, body_blocks: [
        {
          "type" => "products_grid",
          "content" => "<h2>Подборка</h2>",
          "slider_product_skus" => [product.sku]
        }
      ])

      serialized = ContentArticleSerializer.new(article, params: {
        body_block_products_map: { product.sku => product },
        product_serializer_params: { favorite_skus: [] }
      }).serializable_hash
      block = serialized[:data][:attributes][:body_blocks].first

      expect(block["html"]).to eq("<h2>Подборка</h2>")
      expect(block["grid_products"].first[:sku]).to eq(product.sku)
    end
  end
end
