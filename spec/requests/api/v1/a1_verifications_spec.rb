require 'rails_helper'

RSpec.describe 'A1 verifications', type: :request do
  describe 'POST /api/v1/a1/request' do
    let(:phone) { '+375291112233' }

    before do
      allow(PhoneAuthService).to receive(:send_code) do |phone:, metadata:|
        VerificationCode.create!(phone: phone.gsub(/\D/, ''), code: '1234', expires_at: 10.minutes.from_now)
        { success: true, message: 'Ожидайте звонок. Введите последние 4 цифры номера.' }
      end
    end

    it 'does not throttle repeated call requests' do
      PhoneVerificationRequest.create!(
        phone: phone.gsub(/\D/, ''),
        status: 'success',
        context: 'passport_update',
        created_at: Time.current
      )

      post '/api/v1/a1/request', params: { phone: phone, context: 'passport_update' }

      expect(response).to have_http_status(:created)
      expect(PhoneAuthService).to have_received(:send_code).once
    end
  end
end
