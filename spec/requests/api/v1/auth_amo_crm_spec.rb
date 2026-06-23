# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth AmoCRM integration", type: :request do
  let(:phone) { "375291234567" }

  before do
    allow(CrmIntegrationService).to receive(:update_last_login)
  end

  it "updates last login in AmoCRM after successful phone verify" do
    user = create(:user, phone: phone, username: "Existing User")
    VerificationCode.create!(
      phone: phone,
      code: "1234",
      expires_at: 10.minutes.from_now
    )

    post "/api/v1/auth/phone/verify",
         params: { phone: "+#{phone}", code: "1234" }

    expect(response).to have_http_status(:ok)
    expect(CrmIntegrationService).to have_received(:update_last_login).with(user)
  end

  it "does not update last login when verification fails" do
    create(:user, phone: phone)

    post "/api/v1/auth/phone/verify",
         params: { phone: "+#{phone}", code: "0000" }

    expect(response).to have_http_status(:unauthorized)
    expect(CrmIntegrationService).not_to have_received(:update_last_login)
  end
end
