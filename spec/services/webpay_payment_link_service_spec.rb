# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebpayPaymentLinkService do
  describe '.build_form' do
    let(:order) { create(:order, payment_order_number: 'ORDER-1', total_amount: 10.0, payment_method: 'card') }

    around do |example|
      old_return = ENV['WEBPAY_RETURN_URL']
      old_base = ENV['WEBPAY_LINK_BASE_URL']
      ENV['WEBPAY_RETURN_URL'] = return_url_env
      ENV['WEBPAY_LINK_BASE_URL'] = 'https://ikeya.by'
      example.run
    ensure
      ENV['WEBPAY_RETURN_URL'] = old_return
      ENV['WEBPAY_LINK_BASE_URL'] = old_base
      Rails.application.config.x.webpay.return_url = ENV.fetch('WEBPAY_RETURN_URL', '')
      Rails.application.config.x.webpay.link_base_url = ENV.fetch('WEBPAY_LINK_BASE_URL', 'http://localhost:3000')
    end

    before do
      Rails.application.config.x.webpay.return_url = return_url_env.to_s
      Rails.application.config.x.webpay.link_base_url = 'https://ikeya.by'
    end

    context 'when WEBPAY_RETURN_URL points at storefront /payment/success' do
      let(:return_url_env) { 'https://ikeya.by/payment/success/' }

      it 'uses the API success handler instead' do
        form = described_class.build_form(order: order)
        expect(form.fields['wsb_return_url']).to eq('https://ikeya.by/api/v1/payment/success')
      end
    end

    context 'when WEBPAY_RETURN_URL is blank' do
      let(:return_url_env) { '' }

      it 'defaults to the API success handler' do
        form = described_class.build_form(order: order)
        expect(form.fields['wsb_return_url']).to eq('https://ikeya.by/api/v1/payment/success')
      end
    end
  end
end
