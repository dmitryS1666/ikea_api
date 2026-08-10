# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshCategoryFilterIndexJob, type: :job do
  it "refreshes exact IKEA memberships before rebuilding local filters" do
    category = create(:category, ikea_id: "700630")
    execution_order = []
    facet_result = Categories::IkeaFacetMembershipSyncService::Result.new(
      memberships_count: 3,
      unmatched_skus: [],
      errors: []
    )
    facet_service = instance_double(Categories::IkeaFacetMembershipSyncService)
    local_indexer = instance_double(Products::FilterValuesIndexer)

    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .with(category)
      .and_return(facet_service)
    allow(facet_service).to receive(:call) do
      execution_order << :ikea
      facet_result
    end
    allow(Products::FilterValuesIndexer).to receive(:new)
      .and_return(local_indexer)
    allow(local_indexer).to receive(:reindex!) { execution_order << :local }
    allow(Categories::ShowCache).to receive(:bust!)

    result = described_class.perform_now(category.ikea_id)

    expect(result).to eq(facet_result)
    expect(execution_order).to eq(%i[ikea local])
    expect(Categories::ShowCache).to have_received(:bust!).with(category.ikea_id)
  end

  it "raises after preserving successful work when an IKEA facet value failed" do
    category = create(:category, ikea_id: "700630")
    facet_result = Categories::IkeaFacetMembershipSyncService::Result.new(
      memberships_count: 2,
      unmatched_skus: [],
      errors: [{
        "parameter" => "f-colors",
        "value_id" => "10124",
        "message" => "HTTP 500"
      }]
    )
    facet_service = instance_double(
      Categories::IkeaFacetMembershipSyncService,
      call: facet_result
    )
    local_indexer = instance_double(Products::FilterValuesIndexer, reindex!: nil)

    allow(Categories::IkeaFacetMembershipSyncService).to receive(:new)
      .and_return(facet_service)
    allow(Products::FilterValuesIndexer).to receive(:new)
      .and_return(local_indexer)
    allow(Categories::ShowCache).to receive(:bust!)

    expect {
      described_class.perform_now(category.ikea_id)
    }.to raise_error(/f-colors=10124: HTTP 500/)

    expect(local_indexer).to have_received(:reindex!)
    expect(Categories::ShowCache).to have_received(:bust!).with(category.ikea_id)
  end
end
