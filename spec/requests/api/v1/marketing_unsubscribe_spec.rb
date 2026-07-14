# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Marketing unsubscribe", type: :request do
  let!(:user) do
    create(:user, email: "customer@example.com", email_marketing: true, newsletter_consent: true)
  end

  before do
    allow(MarketingSubscriptionService).to receive(:sync_user!)
  end

  it "returns a stable frontend contract after successful unsubscribe" do
    token = Rack::Utils.parse_query(URI(MarketingUnsubscribeService.url_for(user)).query).fetch("token")

    post "/api/v1/marketing/unsubscribe", params: { token: token }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      "success" => true,
      "status" => "unsubscribed",
      "message" => MarketingUnsubscribeService::SUCCESS_MESSAGE
    )
  end

  it "returns an idempotent status for repeated clicks" do
    token = Rack::Utils.parse_query(URI(MarketingUnsubscribeService.url_for(user)).query).fetch("token")
    post "/api/v1/marketing/unsubscribe", params: { token: token }, as: :json
    post "/api/v1/marketing/unsubscribe", params: { token: token }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      "success" => true,
      "status" => "already_unsubscribed"
    )
  end

  it "returns a machine-readable error for an invalid token" do
    post "/api/v1/marketing/unsubscribe", params: { token: "invalid-token" }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)).to include(
      "success" => false,
      "status" => "invalid_token"
    )
  end
end
