# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth registration consent", type: :request do
  include ActiveJob::TestHelper

  let(:phone) { "375291112233" }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    LegalPage.create!(title: "ПД", slug: LegalPage::SLUG_PERSONAL_DATA, body: "x", status: :published)
  end

  it "requires personal_data_consent for new users" do
    verification = VerificationCode.create!(
      phone: phone,
      code: "1234",
      expires_at: 10.minutes.from_now
    )

    post "/api/v1/auth/phone/verify",
         params: {
           phone: phone,
           code: "1234",
           username: "newuser",
           personal_data_consent: false
         }

    expect(response).to have_http_status(:unauthorized)
    body = JSON.parse(response.body)
    expect(body["code"]).to eq("personal_data_consent_required")
    expect(User.exists?(phone: phone)).to be(false)
    expect(VerificationCode.exists?(verification.id)).to be(true)
  end

  it "records personal data consent for new users" do
    VerificationCode.create!(
      phone: phone,
      code: "1234",
      expires_at: 10.minutes.from_now
    )

    post "/api/v1/auth/phone/verify",
         params: {
           phone: phone,
           code: "1234",
           username: "newuser",
           personal_data_consent: true
         }

    expect(response).to have_http_status(:created)
    user = User.find_by!(phone: phone)
    expect(user.personal_data_consent).to be(true)
    expect(user.consent_records.for_type(:personal_data).last.source).to eq("registration")
    expect(CrmSyncJob).to have_been_enqueued.with("User", user.id).at_least(:once)
  end
end
