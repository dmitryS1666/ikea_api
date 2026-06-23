# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReturnRequest, type: :model do
  describe "CRM sync" do
    include ActiveJob::TestHelper

    before do
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
    end

    it "enqueues CrmSyncJob after create" do
      expect do
        create(:return_request)
      end.to have_enqueued_job(CrmSyncJob).with("ReturnRequest", kind_of(Integer))
    end
  end
end
