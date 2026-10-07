# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin access guards", type: :request do
  describe "debug AmoCRM" do
    it "does not sync or exchange tokens" do
      expect(CrmIntegrationService).not_to receive(:sync_order)
      expect(CrmIntegrationService).not_to receive(:sync_user)
      expect(CrmIntegrationService).not_to receive(:exchange_code_for_tokens)

      post "/api/v1/debug/amo_crm/sync_order/1"
      expect(response).to have_http_status(:not_found)

      post "/api/v1/debug/amo_crm/sync_user/1"
      expect(response).to have_http_status(:not_found)

      post "/api/v1/debug/amo_crm/exchange_token", params: { code: "secret" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /admin/products/search" do
    it "does not accept a JWT instead of an admin session" do
      customer = create(:user, role: "user")
      staff = create(:user, role: "site_admin")

      [customer, staff].each do |user|
        token = JwtService.encode(user_id: user.id)
        get "/admin/products/search", params: { q: "table" }, headers: { "Authorization" => "Bearer #{token}" }

        expect(response).to have_http_status(:found)
        expect(response.headers["Location"]).to include("/admin/login")
        expect(response.body).not_to include("\"sku\"")
      end
    end
  end
end
