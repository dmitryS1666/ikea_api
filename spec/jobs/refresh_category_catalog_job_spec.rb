# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshCategoryCatalogJob, type: :job do
  it "runs products, filters and exact facet membership in one parser task" do
    category = create(:category, ikea_id: "20515")
    task = create(:parser_task, task_type: "refresh_category_catalog")
    product_job = instance_double(RefreshCategoryFromLtJob)
    filters_service = instance_double(
      Categories::LtAvailableFiltersRefreshService,
      call: double(changed: true)
    )
    facet_service = instance_double(
      Categories::IkeaFacetMembershipSyncService,
      call: double(memberships_count: 7, unmatched_skus: [])
    )
    local_filters_indexer = instance_double(
      Products::FilterValuesIndexer,
      reindex!: nil
    )

    allow(RefreshCategoryFromLtJob).to receive(:new).and_return(product_job)
    allow(product_job).to receive(:perform).with(
      ikea_id: category.ikea_id,
      task_id: task.id,
      threads: 3,
      manage_task: false
    ).and_return(processed: 5)
    allow(Categories::LtAvailableFiltersRefreshService).to receive(:new)
      .with(category, reindex: false, ensure_series: false)
      .and_return(filters_service)
    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .and_return(facet_service)
    allow(Products::FilterValuesIndexer).to receive(:new)
      .and_return(local_filters_indexer)
    allow(Categories::ShowCache).to receive(:bust!)
    allow(Product).to receive(:catalog_category_scope)
      .with(category.ikea_id)
      .and_return(Product.none)

    described_class.perform_now(ikea_id: category.ikea_id, task_id: task.id, threads: 3)

    expect(task.reload.status).to eq("completed")
    expect(task.processed).to eq(1)
    expect(task.error_count).to eq(0)
    expect(task.payload).to include(
      "stage" => "completed",
      "products_processed" => 5,
      "facet_memberships" => 7
    )
  end

  it "uses every non-deleted category when ikea_id is absent" do
    active = create(:category, ikea_id: "20515")
    create(:category, ikea_id: "20516", is_deleted: true)
    job = described_class.new

    expect(job.send(:categories_scope, nil).pluck(:ikea_id)).to eq([active.ikea_id])
  end
end
