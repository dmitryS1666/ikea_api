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
      call: double(memberships_count: 7, unmatched_skus: [], errors: [])
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
      .with(
        an_object_having_attributes(ikea_id: category.ikea_id),
        reindex: false,
        ensure_series: false
      )
      .and_return(filters_service)
    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .and_return(facet_service)
    allow(Products::FilterValuesIndexer).to receive(:new)
      .and_return(local_filters_indexer)
    allow(Categories::ShowCache).to receive(:bust!)

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

  it "keeps later stages running and marks the task failed when one facet value fails" do
    category = create(:category, ikea_id: "57542")
    task = create(:parser_task, task_type: "refresh_category_catalog")
    product_job = instance_double(RefreshCategoryFromLtJob)
    facet_result = Categories::IkeaFacetMembershipSyncService::Result.new(
      memberships_count: 2,
      unmatched_skus: [],
      errors: [{
        "parameter" => "f-home-smart",
        "value_id" => "true",
        "error_class" => "RuntimeError",
        "message" => "HTTP 400"
      }]
    )
    local_filters_indexer = instance_double(Products::FilterValuesIndexer, reindex!: nil)

    allow(RefreshCategoryFromLtJob).to receive(:new).and_return(product_job)
    allow(product_job).to receive(:perform).and_return(processed: 3)
    allow(Categories::LtAvailableFiltersRefreshService).to receive(:new)
      .and_return(instance_double(Categories::LtAvailableFiltersRefreshService, call: nil))
    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .and_return(instance_double(Categories::IkeaFacetMembershipSyncService, call: facet_result))
    allow(Products::FilterValuesIndexer).to receive(:new).and_return(local_filters_indexer)
    allow(Categories::ShowCache).to receive(:bust!)
    allow(Product).to receive(:catalog_category_scope).and_return(Product.none)

    described_class.perform_now(ikea_id: category.ikea_id, task_id: task.id)

    expect(local_filters_indexer).to have_received(:reindex!)
    expect(task.reload.status).to eq("failed")
    expect(task.processed).to eq(1)
    expect(task.error_count).to eq(1)
    expect(task.payload).to include(
      "stage" => "completed_with_errors",
      "products_processed" => 3,
      "facet_memberships" => 2
    )
    expect(task.payload.dig("facet_errors", category.ikea_id).first).to include(
      "parameter" => "f-home-smart",
      "value_id" => "true",
      "message" => "HTTP 400"
    )
  end

  it "uses every non-deleted category when ikea_id is absent" do
    active = create(:category, ikea_id: "20515")
    create(:category, ikea_id: "20516", is_deleted: true)
    job = described_class.new

    expect(job.send(:categories_scope, nil).pluck(:ikea_id)).to eq([active.ikea_id])
  end

  it "includes the requested top-level category and every non-deleted descendant" do
    parent = create(:category, ikea_id: "57542", parent_ids: [])
    child = create(:category, ikea_id: "50003", parent_ids: [parent.ikea_id])
    grandchild = create(
      :category,
      ikea_id: "50004",
      parent_ids: [parent.ikea_id, child.ikea_id]
    )
    create(:category, ikea_id: "50005", parent_ids: [parent.ikea_id], is_deleted: true)
    create(:category, ikea_id: "outside", parent_ids: [])

    scope = described_class.new.send(:categories_scope, parent.ikea_id)

    expect(scope).to contain_exactly(parent, child, grandchild)
  end

  it "refreshes descendants before the parent and finalizes parent filters" do
    parent = create(:category, ikea_id: "57542", parent_ids: [])
    child = create(:category, ikea_id: "50003", parent_ids: [parent.ikea_id])
    task = create(:parser_task, task_type: "refresh_category_catalog")
    execution_order = []

    product_job = instance_double(RefreshCategoryFromLtJob)
    allow(RefreshCategoryFromLtJob).to receive(:new).and_return(product_job)
    allow(product_job).to receive(:perform) do |args|
      execution_order << args[:ikea_id]
      { processed: 1 }
    end

    allow(Categories::LtAvailableFiltersRefreshService).to receive(:new)
      .and_return(instance_double(Categories::LtAvailableFiltersRefreshService, call: double(changed: false)))
    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .and_return(
        instance_double(
          Categories::IkeaFacetMembershipSyncService,
          call: double(memberships_count: 1, unmatched_skus: [], errors: [])
        )
      )

    indexer = instance_double(Products::FilterValuesIndexer, reindex!: nil)
    allow(Products::FilterValuesIndexer).to receive(:new).and_return(indexer)
    merge_service = instance_double(
      Categories::MergeDescendantAvailableFiltersService,
      call: double(merge_changed: true)
    )
    allow(Categories::MergeDescendantAvailableFiltersService).to receive(:new)
      .with(an_object_having_attributes(ikea_id: parent.ikea_id))
      .and_return(merge_service)
    allow(Categories::ShowCache).to receive(:bust!)
    allow(Product).to receive(:catalog_category_scope).and_return(Product.none)

    described_class.perform_now(ikea_id: parent.ikea_id, task_id: task.id)

    expect(execution_order).to eq([child.ikea_id, parent.ikea_id])
    expect(Categories::MergeDescendantAvailableFiltersService).to have_received(:new).once
    # Один reindex на каждый узел и ещё один для родителя после merge.
    expect(indexer).to have_received(:reindex!).exactly(3).times
    expect(task.reload.status).to eq("completed")
    expect(task.processed).to eq(2)
    expect(task.payload["products_processed"]).to eq(2)
  end

  context "with resumable checkpoints" do
    let(:product_job) { instance_double(RefreshCategoryFromLtJob) }
    let(:local_filters_indexer) { instance_double(Products::FilterValuesIndexer, reindex!: nil) }
    let(:facet_result) do
      Categories::IkeaFacetMembershipSyncService::Result.new(
        memberships_count: 1,
        unmatched_skus: [],
        errors: []
      )
    end

    before do
      allow(RefreshCategoryFromLtJob).to receive(:new).and_return(product_job)
      allow(Categories::LtAvailableFiltersRefreshService).to receive(:new)
        .and_return(instance_double(Categories::LtAvailableFiltersRefreshService, call: nil))
      allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
        .and_return(instance_double(Categories::IkeaFacetMembershipSyncService, call: facet_result))
      allow(Products::FilterValuesIndexer).to receive(:new).and_return(local_filters_indexer)
      allow(Categories::ShowCache).to receive(:bust!)
      allow(Product).to receive(:catalog_category_scope).and_return(Product.none)
    end

    it "resumes only failed and unfinished categories" do
      failed_category = create(:category, ikea_id: "10001")
      completed_category = create(:category, ikea_id: "10002")
      task = create(:parser_task, task_type: "refresh_category_catalog")
      calls = []
      failed_once = false

      allow(product_job).to receive(:perform) do |args|
        calls << args[:ikea_id]
        if args[:ikea_id] == failed_category.ikea_id && !failed_once
          failed_once = true
          raise ArgumentError, "invalid upstream response"
        end

        { processed: 1 }
      end

      described_class.perform_now(task_id: task.id, threads: 3)

      expect(task.reload.status).to eq("failed")
      expect(task.payload["completed_category_ids"]).to eq([completed_category.ikea_id])
      expect(task.payload["failed_category_ids"]).to eq([failed_category.ikea_id])
      expect(task.payload["category_ids"]).to contain_exactly(
        failed_category.ikea_id,
        completed_category.ikea_id
      )

      calls.clear
      described_class.perform_now(task_id: task.id, resume: true)

      expect(calls).to eq([failed_category.ikea_id])
      expect(task.reload.status).to eq("completed")
      expect(task.processed).to eq(2)
      expect(task.updated).to eq(2)
      expect(task.error_count).to eq(0)
      expect(task.payload["completed_category_ids"]).to contain_exactly(
        failed_category.ikea_id,
        completed_category.ikea_id
      )
      expect(task.payload["failed_category_ids"]).to be_empty
      expect(task.payload["products_processed"]).to eq(2)
    end

    it "retries transient stage failures up to three times" do
      category = create(:category, ikea_id: "20001")
      task = create(:parser_task, task_type: "refresh_category_catalog")
      job = described_class.new
      attempts = 0

      allow(job).to receive(:sleep)
      allow(product_job).to receive(:perform) do
        attempts += 1
        raise StandardError, "connection timed out" if attempts < 3

        { processed: 1 }
      end

      job.perform(ikea_id: category.ikea_id, task_id: task.id)

      expect(attempts).to eq(3)
      expect(job).to have_received(:sleep).with(1).once
      expect(job).to have_received(:sleep).with(3).once
      expect(task.reload.status).to eq("completed")
      expect(task.payload.dig("last_retry", "stage")).to eq("products")
      expect(task.payload.dig("last_retry", "attempt")).to eq(2)
    end

    it "retries transient facet result errors before recording them" do
      category = create(:category, ikea_id: "20002")
      task = create(:parser_task, task_type: "refresh_category_catalog")
      job = described_class.new
      failed_result = Categories::IkeaFacetMembershipSyncService::Result.new(
        memberships_count: 0,
        unmatched_skus: [],
        errors: [{
          "parameter" => "f-test",
          "value_id" => "value",
          "error_class" => "RuntimeError",
          "message" => "HTTP 500"
        }]
      )
      successful_result = Categories::IkeaFacetMembershipSyncService::Result.new(
        memberships_count: 4,
        unmatched_skus: [],
        errors: []
      )

      allow(job).to receive(:sleep)
      allow(product_job).to receive(:perform).and_return(processed: 1)
      allow(Categories::IkeaFacetMembershipSyncService).to receive(:new).and_return(
        instance_double(Categories::IkeaFacetMembershipSyncService, call: failed_result),
        instance_double(Categories::IkeaFacetMembershipSyncService, call: successful_result)
      )

      job.perform(ikea_id: category.ikea_id, task_id: task.id)

      expect(Categories::IkeaFacetMembershipSyncService).to have_received(:new).twice
      expect(job).to have_received(:sleep).with(1).once
      expect(task.reload.status).to eq("completed")
      expect(task.error_count).to eq(0)
      expect(task.payload["facet_errors"]).to be_empty
      expect(task.payload["facet_memberships"]).to eq(4)
    end

    it "retries only failed categories when retry_failed is requested" do
      failed_category = create(:category, ikea_id: "30001")
      untouched_category = create(:category, ikea_id: "30002")
      task = create(
        :parser_task,
        task_type: "refresh_category_catalog",
        status: "failed",
        payload: {
          "ikea_id" => nil,
          "threads" => 2,
          "category_ids" => [failed_category.ikea_id, untouched_category.ikea_id],
          "attempted_category_ids" => [failed_category.ikea_id],
          "completed_category_ids" => [],
          "failed_category_ids" => [failed_category.ikea_id],
          "category_errors" => {
            failed_category.ikea_id => { "message" => "HTTP 500" }
          }
        }
      )
      calls = []

      allow(product_job).to receive(:perform) do |args|
        calls << args[:ikea_id]
        { processed: 1 }
      end

      described_class.perform_now(task_id: task.id, retry_failed: true)

      expect(calls).to eq([failed_category.ikea_id])
      expect(task.reload.status).to eq("failed")
      expect(task.error_count).to eq(0)
      expect(task.payload["stage"]).to eq("incomplete")
      expect(task.payload["completed_category_ids"]).to eq([failed_category.ikea_id])
      expect(task.payload["failed_category_ids"]).to be_empty
    end

    it "continues filters/facets after soft product failures and records failed enrichment" do
      category = create(:category, ikea_id: "40001")
      task = create(:parser_task, task_type: "refresh_category_catalog")
      filters_service = instance_double(Categories::LtAvailableFiltersRefreshService, call: nil)
      facet_service = instance_double(
        Categories::IkeaFacetMembershipSyncService,
        call: double(memberships_count: 1, unmatched_skus: [], errors: [])
      )
      local_filters_indexer = instance_double(Products::FilterValuesIndexer, reindex!: nil)

      allow(product_job).to receive(:perform) do
        {
          processed: 1,
          products_completed: 1,
          failed_enrichment_skus: ["22222222"]
        }
      end
      allow(Categories::LtAvailableFiltersRefreshService).to receive(:new).and_return(filters_service)
      allow(Categories::IkeaFacetMembershipSyncService).to receive(:new).and_return(facet_service)
      allow(Products::FilterValuesIndexer).to receive(:new).and_return(local_filters_indexer)
      allow(Categories::ShowCache).to receive(:bust!)
      allow(Product).to receive(:catalog_category_scope).and_return(Product.none)

      described_class.perform_now(ikea_id: category.ikea_id, task_id: task.id)

      expect(filters_service).to have_received(:call)
      expect(facet_service).to have_received(:call)
      expect(task.reload.status).to eq("completed")
      expect(task.payload.dig("product_quality_issues", category.ikea_id, "failed_enrichment"))
        .to include("22222222")
      expect(task.payload["category_errors"]).to be_blank
    end
  end
end
