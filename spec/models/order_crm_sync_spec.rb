# frozen_string_literal: true

require "rails_helper"

RSpec.describe Order, type: :model do
  describe "CRM sync callbacks" do
    include ActiveJob::TestHelper

    before do
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
    end

    it "enqueues CrmSyncJob on create when order is not a draft" do
      expect do
        create(:order, checkout_draft: false)
      end.to have_enqueued_job(CrmSyncJob).with("Order", kind_of(Integer))
    end

    it "does not enqueue CrmSyncJob on draft create" do
      user = create(:user)
      clear_enqueued_jobs

      expect do
        create(:order, user: user, checkout_draft: true)
      end.not_to have_enqueued_job(CrmSyncJob).with("Order", kind_of(Integer))
    end

    it "enqueues CrmSyncJob when checkout draft is finalized" do
      order = create(:order, checkout_draft: true)

      expect do
        order.update!(checkout_draft: false)
      end.to have_enqueued_job(CrmSyncJob).with("Order", order.id)
    end

    it "does not enqueue CrmSyncJob on unrelated order updates" do
      order = create(:order, checkout_draft: false)
      clear_enqueued_jobs

      expect do
        order.update!(full_name: "Another Name")
      end.not_to have_enqueued_job(CrmSyncJob)
    end
  end
end
