require 'rails_helper'

RSpec.describe "Api::V1::Auth", type: :request do
  describe "POST /api/v1/auth/phone/send" do
    let(:phone) { "79991234567" }
    
    before do
      allow(SmsSenderService).to receive(:send).and_return(true)
    end

    it "creates a PhoneVerificationRequest and returns success" do
      expect {
        post "/api/v1/auth/phone/send", params: { phone: phone }
      }.to change(PhoneVerificationRequest, :count).by(1)

      expect(response).to have_http_status(:ok)
      
      request = PhoneVerificationRequest.last
      expect(request.phone).to eq(phone)
      expect(request.code).to be_present
      expect(request.status).to eq('success')
      expect(request.ip_address).to be_present
    end

    it "records error if phone is blank" do
      expect {
        post "/api/v1/auth/phone/send", params: { phone: "" }
      }.to change(PhoneVerificationRequest, :count).by(1)

      expect(response).to have_http_status(:unprocessable_entity)
      
      request = PhoneVerificationRequest.last
      expect(request.status).to eq('error')
      expect(request.error_message).to eq('Неверный формат телефона')
    end

    it "records error if SMS sending fails" do
      allow(SmsSenderService).to receive(:send).and_raise(StandardError.new("SMS Gateway Error"))

      expect {
        post "/api/v1/auth/phone/send", params: { phone: phone }
      }.to change(PhoneVerificationRequest, :count).by(1)

      expect(response).to have_http_status(:unprocessable_entity)
      
      request = PhoneVerificationRequest.last
      expect(request.status).to eq('error')
      expect(request.error_message).to eq('SMS Gateway Error')
    end
  end
end
