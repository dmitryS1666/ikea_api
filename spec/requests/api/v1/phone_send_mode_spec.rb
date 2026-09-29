require 'rails_helper'

RSpec.describe 'POST /api/v1/auth/phone/send modes', type: :request do
  let(:phone) { '375291234567' }

  before do
    PhoneAuthSetting.instance.update!(asterisk_enabled: asterisk_enabled)
  end

  context 'when Asterisk is disabled (static code)' do
    let(:asterisk_enabled) { false }

    it 'returns mode=static and the static code without initiating a call' do
      expect(AsteriskCallAuthService).not_to receive(:initiate_call)

      post '/api/v1/auth/phone/send', params: { phone: phone }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['message']).to be_present
      expect(json['mode']).to eq('static')
      expect(json['code']).to eq(PhoneAuthSetting::STATIC_TEST_CODE)
      expect(VerificationCode.find_by(phone: phone)&.code).to eq(PhoneAuthSetting::STATIC_TEST_CODE)
    end
  end

  context 'when Asterisk is enabled (real call)' do
    let(:asterisk_enabled) { true }

    before do
      allow(AsteriskCallAuthService).to receive(:get_caller_info).and_return(
        code: '4321',
        number: '375290000001'
      )
      allow(AsteriskCallAuthService).to receive(:initiate_call).and_return(success: true)
    end

    it 'returns mode=call without exposing the code' do
      post '/api/v1/auth/phone/send', params: { phone: phone }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['message']).to be_present
      expect(json['mode']).to eq('call')
      expect(json).not_to have_key('code')
      expect(AsteriskCallAuthService).to have_received(:initiate_call).once
    end
  end
end

RSpec.describe 'POST /api/v1/a1/request modes', type: :request do
  let(:phone) { '+375291112233' }

  before do
    PhoneAuthSetting.instance.update!(asterisk_enabled: asterisk_enabled)
  end

  context 'when Asterisk is disabled' do
    let(:asterisk_enabled) { false }

    it 'returns static mode and code without embedding code in caller mask' do
      post '/api/v1/a1/request', params: { phone: phone, context: 'passport_update' }

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json['mode']).to eq('static')
      expect(json['code']).to eq(PhoneAuthSetting::STATIC_TEST_CODE)
      expect(json['caller_number_masked']).to eq('+375 (**) ***-**-**')
      expect(json['caller_number_masked']).not_to include(PhoneAuthSetting::STATIC_TEST_CODE)
    end
  end

  context 'when Asterisk is enabled' do
    let(:asterisk_enabled) { true }

    before do
      allow(AsteriskCallAuthService).to receive(:get_caller_info).and_return(
        code: '9876',
        number: '375290000002'
      )
      allow(AsteriskCallAuthService).to receive(:initiate_call).and_return(success: true)
    end

    it 'returns call mode without code and without leaking digits in mask' do
      post '/api/v1/a1/request', params: { phone: phone, context: 'checkout' }

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json['mode']).to eq('call')
      expect(json).not_to have_key('code')
      expect(json['caller_number_masked']).to eq('+375 (**) ***-**-**')
      expect(json['caller_number_masked']).not_to include('9876')
    end
  end
end
