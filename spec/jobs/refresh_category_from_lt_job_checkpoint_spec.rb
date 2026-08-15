# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshCategoryFromLtJob do
  let(:job) { described_class.new }
  let(:category) { create(:category, ikea_id: "47388") }
  let(:first_product) { create(:product, sku: "11111111") }
  let(:second_product) { create(:product, sku: "22222222") }
  let(:task) do
    create(
      :parser_task,
      task_type: "refresh_category_catalog",
      payload: {
        described_class::PRODUCT_CHECKPOINT_KEY => {
          "category_ikea_id" => category.ikea_id,
          "listing_skus" => [first_product.sku, second_product.sku],
          "completed_skus" => [first_product.sku],
          "failed_skus" => {
            second_product.sku => {
              "error_class" => "PlDetailsFetcher::HeadlessTimeoutError",
              "message" => "headless timeout"
            }
          }
        }
      }
    )
  end

  it "continues product enrichment with only unfinished and failed SKU" do
    checkpoint = job.send(
      :prepare_product_checkpoint!,
      task,
      category,
      [first_product.id, second_product.id]
    )

    expect(job.send(:pending_product_ids, [first_product.id, second_product.id], checkpoint))
      .to eq([second_product.id])
    expect(checkpoint["completed_skus"]).to eq([first_product.sku])
    expect(checkpoint["failed_skus"]).to have_key(second_product.sku)
  end

  it "moves a successfully retried SKU from failed to completed" do
    checkpoint = job.send(
      :prepare_product_checkpoint!,
      task,
      category,
      [first_product.id, second_product.id]
    )

    job.send(
      :persist_product_checkpoint_result!,
      task,
      checkpoint,
      second_product,
      { ok: true }
    )

    saved = task.reload.payload.fetch(described_class::PRODUCT_CHECKPOINT_KEY)
    expect(saved["completed_skus"]).to contain_exactly(first_product.sku, second_product.sku)
    expect(saved["failed_skus"]).to be_empty
    expect(saved["last_product_sku"]).to eq(second_product.sku)
  end

  it "keeps the original product error for a targeted retry" do
    checkpoint = job.send(
      :prepare_product_checkpoint!,
      task,
      category,
      [first_product.id, second_product.id]
    )
    job.send(
      :persist_product_checkpoint_result!,
      task,
      checkpoint,
      second_product,
      {
        ok: false,
        error_class: "PlDetailsFetcher::HeadlessFetchError",
        message: "headless proxy blocked by IKEA (HTTP 403/Cloudflare)"
      }
    )

    expect { job.send(:raise_product_stage_incomplete!, task, checkpoint, strict: true) }
      .to raise_error(
        RefreshCategoryFromLtJob::ProductStageIncompleteError,
        /22222222.*HTTP 403\/Cloudflare/
      )
  end

  it "uses light HTML for variant PL fallback when images already exist" do
    product = create(
      :product,
      sku: "20404806",
      images: ["https://ikea.example/a.jpg", "https://ikea.example/b.jpg"],
      local_images: ["a.webp", "b.webp"]
    )

    expect(PlDetailsFetcher).to receive(:fetch).with(
      "https://www.ikea.com/pl/pl/p/-20404806/",
      use_headless: false,
      scope_sku: "20404806"
    ).and_return({})

    job.send(:ensure_variant_critical_pl_data_from_payload_sku!, product, "20404806")
  end

  it "soft-continues when product stage is incomplete and strict mode is off" do
    checkpoint = job.send(
      :prepare_product_checkpoint!,
      task,
      category,
      [first_product.id, second_product.id]
    )

    expect { job.send(:raise_product_stage_incomplete!, task, checkpoint, strict: false) }
      .not_to raise_error

    saved = task.reload.payload.fetch(described_class::PRODUCT_CHECKPOINT_KEY)
    expect(saved["failed_skus"]).to have_key(second_product.sku)

    job.send(:finalize_product_checkpoint!, task, checkpoint)
    saved = task.reload.payload.fetch(described_class::PRODUCT_CHECKPOINT_KEY)
    expect(saved["stage"]).to eq("products_completed")
    expect(saved["failed_skus"]).to have_key(second_product.sku)
  end

  it "records a failed listing row and prevents unsafe orphan detachment" do
    parser = double("listing parser")
    allow(parser).to receive(:process_product).and_raise("temporary listing error")
    stats = { errors: 0, listing_errors: [] }

    result = job.send(
      :process_one_listing_item,
      { "id" => "33333333" },
      parser,
      category,
      {},
      task,
      stats,
      nil
    )

    expect(result).to be_nil
    expect(stats[:listing_errors]).to contain_exactly(include(
      "sku" => "33333333",
      "message" => "temporary listing error"
    ))
  end

  it "keeps depth-1 listing extras when detaching orphans" do
    listing = create(:product, sku: "s99614849")
    extra = create(:product, sku: "s69614742")
    CategoryProduct.create!(product: listing, category_id: category.ikea_id)
    CategoryProduct.create!(product: extra, category_id: category.ikea_id)
    stray = create(:product, sku: "s11111111")
    CategoryProduct.create!(product: stray, category_id: category.ikea_id)

    job.instance_variable_set(:@listing_variant_skus_by_sku, { listing.sku => [extra.sku] })
    keep = [listing.sku] + job.send(:remembered_listing_variant_skus)

    expect { job.send(:detach_category_products_not_in_listing, category, keep) }
      .to change { CategoryProduct.where(product: stray, category_id: category.ikea_id).count }.from(1).to(0)

    expect(CategoryProduct.where(product: extra, category_id: category.ikea_id)).to exist
    expect(CategoryProduct.where(product: listing, category_id: category.ikea_id)).to exist
  end

  it "unions capped listing extras with PIP payload SKUs" do
    parent = create(
      :product,
      sku: "s99614849",
      variants_payload: [
        { "type" => "color", "data" => [{ "item" => { "sku" => "s39614753" } }] }
      ].to_json
    )
    job.instance_variable_set(:@listing_variant_skus_by_sku, { parent.sku => %w[s69614742] })

    expect(job.send(:variant_skus_for, parent)).to contain_exactly("s39614753", "s69614742")
  end
end
