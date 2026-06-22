# frozen_string_literal: true

require "rails_helper"

RSpec.describe "SendPulse webhook", type: :request do
  include ActiveJob::TestHelper

  let!(:user) { create(:user, email: "user@example.com", email_marketing: true, newsletter_consent: true) }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(MarketingSubscriptionService).to receive(:sync_user!)
  end

  it "processes unsubscribe events" do
    post "/api/v1/webhooks/sendpulse",
         params: { event: "unsubscribe", email: "user@example.com" },
         as: :json

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.email_marketing).to be(false)
    expect(user.newsletter_consent).to be(false)
  end

  it "ignores unknown events" do
    post "/api/v1/webhooks/sendpulse",
         params: { event: "delivered", email: "user@example.com" },
         as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["ignored"]).to be(true)
    expect(user.reload.email_marketing).to be(true)
  end
end
