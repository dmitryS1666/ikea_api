# frozen_string_literal: true

require "rails_helper"

RSpec.describe CooperationRequest, type: :model do
  include ActiveJob::TestHelper

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  describe "validations" do
    subject(:request) { build(:cooperation_request) }

    it { is_expected.to be_valid }

    it "requires personal_data_consent to be accepted" do
      request.personal_data_consent = false

      expect(request).not_to be_valid
      expect(request.errors[:personal_data_consent]).to be_present
    end

    it "allows marketing_email_consent to be false" do
      request.marketing_email_consent = false

      expect(request).to be_valid
    end

    it "allows marketing_email_consent to be true" do
      request.marketing_email_consent = true

      expect(request).to be_valid
    end

    it "rejects nil marketing_email_consent" do
      request.marketing_email_consent = nil

      expect(request).not_to be_valid
      expect(request.errors[:marketing_email_consent]).to be_present
    end
  end

  describe "CRM sync" do
    it "enqueues CrmSyncJob after create" do
      expect do
        create(:cooperation_request)
      end.to have_enqueued_job(CrmSyncJob).with("CooperationRequest", kind_of(Integer))
    end
  end
end
