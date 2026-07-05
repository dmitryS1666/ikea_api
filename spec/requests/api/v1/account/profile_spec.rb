# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account Profile API", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user, phone: "375291112233") }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  let(:passport_payload) do
    {
      passport_number: "MP1234567",
      series: nil,
      first_name: "Иван",
      last_name: "Иванов",
      middle_name: "Иванович",
      dob: "1990-01-01",
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
      expect(user.first_name).to eq("Иван")
      expect(user.last_name).to eq("Иванов")
      expect(user.middle_name).to eq("Иванович")
      expect(user.dob).to eq(Date.parse("1990-01-01"))
      expect(user.passport_verified?).to be true
      expect(user.a1_verification_id).to eq(verification.id.to_s)
      expect(VerificationCode.exists?(verification.id)).to be false
    end

    it "maps passport date_of_birth to profile dob" do
      verification = VerificationCode.create!(
        phone: user.phone,
        code: "1234",
        expires_at: 10.minutes.from_now
      )

      patch "/api/v1/account/profile",
            params: {
              passport: passport_payload.merge(dob: nil, date_of_birth: "1991-02-03"),
              verification_id: verification.id,
              code: "1234"
            },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.reload.dob).to eq(Date.parse("1991-02-03"))
    end

    it "does not save passport with a valid code for another phone" do
      verification = VerificationCode.create!(
        phone: "375291119999",
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

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("invalid_verification_code")
      expect(user.reload.passport_data).to be_nil
      expect(VerificationCode.exists?(verification.id)).to be true
    end

    it "allows checking the call code before saving passport" do
      verification = VerificationCode.create!(
        phone: user.phone,
        code: "1234",
        expires_at: 10.minutes.from_now
      )

      post "/api/v1/a1/verify",
           params: { verification_id: verification.id, last4: "1234" },
           headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
      expect(VerificationCode.exists?(verification.id)).to be true

      patch "/api/v1/account/profile",
            params: {
              passport: passport_payload,
              verification_id: verification.id,
              code: "1234"
            },
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.reload.passport_data).to include("passport_number" => "MP1234567")
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

    it "updates marketing and privacy consent flags" do
      patch "/api/v1/account/profile",
            params: {
              gdpr_consent: true,
              newsletter_consent: true,
              email_marketing: true,
              telegram_marketing: false
            },
            headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["gdpr_consent"]).to be(true)
      expect(body["newsletter_consent"]).to be(true)
      expect(body["email_marketing"]).to be(true)
      expect(body["telegram_marketing"]).to be(false)

      user.reload
      expect(user.gdpr_consent).to be(true)
      expect(user.newsletter_consent).to be(true)
      expect(user.email_marketing).to be(true)
      expect(user.telegram_marketing).to be(false)
    end

    it "allows unsubscribing from all marketing channels" do
      user.update!(
        gdpr_consent: true,
        newsletter_consent: true,
        email_marketing: true,
        telegram_marketing: true
      )

      expect do
        patch "/api/v1/account/profile",
              params: {
                newsletter_consent: false,
                email_marketing: false,
                telegram_marketing: false
              },
              headers: headers
      end.to have_enqueued_job(CrmSyncJob).with("User", user.id)
         .and have_enqueued_job(SendpulseMarketingSyncJob).with(user.id, "unsubscribe")

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["newsletter_consent"]).to be(false)
      expect(body["email_marketing"]).to be(false)
      expect(body["telegram_marketing"]).to be(false)

      user.reload
      expect(user.newsletter_consent).to be(false)
      expect(user.email_marketing).to be(false)
      expect(user.telegram_marketing).to be(false)
      expect(user.gdpr_consent).to be(true)
      expect(user.consent_records.for_type(:newsletter_email).last.accepted).to be(false)
    end
  end

  describe "GET /api/v1/account/profile" do
    it "returns marketing and privacy consent flags" do
      user.update!(
        gdpr_consent: true,
        newsletter_consent: false,
        email_marketing: false,
        telegram_marketing: true
      )

      get "/api/v1/account/profile", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["gdpr_consent"]).to be(true)
      expect(body["newsletter_consent"]).to be(false)
      expect(body["email_marketing"]).to be(false)
      expect(body["telegram_marketing"]).to be(true)
    end

    it "returns profile names and birth date from passport for legacy records" do
      user.update_columns(
        first_name: nil,
        last_name: nil,
        middle_name: nil,
        dob: nil,
        encrypted_passport_json: {
          first_name: "Петр",
          last_name: "Петров",
          middle_name: "Петрович",
          dob: "1988-08-08",
          passport_number: "MP1234567"
        }.to_json
      )

      get "/api/v1/account/profile", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["first_name"]).to eq("Петр")
      expect(body["last_name"]).to eq("Петров")
      expect(body["middle_name"]).to eq("Петрович")
      expect(body["dob"]).to eq("1988-08-08")
      expect(body.dig("passport_data", "first_name")).to eq("Петр")
      expect(body.dig("passport_data", "dob")).to eq("1988-08-08")
    end

    it "keeps passport_data aligned with profile fields in response" do
      user.update_columns(
        first_name: "Анна",
        encrypted_passport_json: {
          first_name: "СтароеИмя",
          passport_number: "MP7654321"
        }.to_json
      )

      get "/api/v1/account/profile", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["first_name"]).to eq("Анна")
      expect(body.dig("passport_data", "first_name")).to eq("Анна")
    end
  end
end
