# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account Profile API", type: :request do
  let(:user) { create(:user, phone: "375291112233") }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  let(:passport_payload) do
    {
      passport_number: "MP1234567",
      series: nil,
      issued_by: "МВД",
      issued_at: "2020-01-01"
    }
  end

  describe "PATCH /api/v1/account/profile" do
    it "does not save passport without verification" do
      patch "/api/v1/account/profile",
            params: { passport: passport_payload },
            headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("passport_verification_required")
      expect(user.reload.passport_data).to be_nil
      expect(user.passport_verified?).to be false
    end

    it "does not save passport when verification code is invalid" do
      verification = VerificationCode.create!(
        phone: user.phone,
        code: "1234",
        expires_at: 10.minutes.from_now
      )

      patch "/api/v1/account/profile",
            params: {
              passport: passport_payload,
              verification_id: verification.id,
              code: "9999"
            },
            headers: headers

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("invalid_verification_code")
      expect(user.reload.passport_data).to be_nil
      expect(VerificationCode.exists?(verification.id)).to be true
    end

    it "saves passport and marks verified when code is valid" do
      verification = VerificationCode.create!(
        phone: user.phone,
        code: "1234",
        expires_at: 10.minutes.from_now
      )

      patch "/api/v1/account/profile",
            params: {
              passport: passport_payload,
              verification_id: verification.id,
              code: "1234"
            },
            headers: headers

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.passport_data).to include("passport_number" => "MP1234567")
      expect(user.passport_verified?).to be true
      expect(user.a1_verification_id).to eq(verification.id.to_s)
      expect(VerificationCode.exists?(verification.id)).to be false
    end

    it "updates other profile fields without passport verification" do
      patch "/api/v1/account/profile",
            params: { first_name: "Иван" },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.reload.first_name).to eq("Иван")
    end

    it "normalizes gender from the storefront format" do
      patch "/api/v1/account/profile",
            params: { gender: "female" },
            headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["gender"]).to eq("Female")
      expect(user.reload.read_attribute(:gender)).to eq("Female")
    end
  end
end
