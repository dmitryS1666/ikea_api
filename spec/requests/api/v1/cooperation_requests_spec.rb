# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cooperation Requests API", type: :request do
  include ActiveJob::TestHelper

  let(:valid_params) do
    {
      first_name: "Иван",
      last_name: "Петров",
      email: "ivan@example.com",
      phone: "375291112233",
      city: "Минск",
      cooperation_type: "dealer",
      comment: "Интересует оптовое сотрудничество",
      personal_data_consent: true,
      marketing_email_consent: false
    }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  describe "POST /api/v1/cooperation_requests" do
    it "creates request and stores consent flags" do
      expect do
        post "/api/v1/cooperation_requests", params: valid_params
      end.to change(CooperationRequest, :count).by(1)
         .and have_enqueued_job(CrmSyncJob).with("CooperationRequest", kind_of(Integer))

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)["cooperation_request"]
      expect(body["personal_data_consent"]).to be(true)
      expect(body["marketing_email_consent"]).to be(false)
      expect(body["first_name"]).to eq("Иван")
      expect(body["status"]).to eq("new")

      record = CooperationRequest.last
      expect(record.personal_data_consent).to be(true)
      expect(record.marketing_email_consent).to be(false)
    end

    it "stores marketing_email_consent when user opts in" do
      post "/api/v1/cooperation_requests",
           params: valid_params.merge(marketing_email_consent: true)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig("cooperation_request", "marketing_email_consent")).to be(true)
      expect(CooperationRequest.last.marketing_email_consent).to be(true)
    end

    it "rejects submission without personal_data_consent" do
      expect do
        post "/api/v1/cooperation_requests",
             params: valid_params.merge(personal_data_consent: false)
      end.not_to change(CooperationRequest, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
