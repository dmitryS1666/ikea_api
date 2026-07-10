require 'rails_helper'

RSpec.describe 'WebPay payment success redirect', type: :request do
  around do |example|
    old_success = ENV['WEBPAY_SUCCESS_REDIRECT_URL']
    ENV['WEBPAY_SUCCESS_REDIRECT_URL'] = redirect_target
    example.run
  ensure
    ENV['WEBPAY_SUCCESS_REDIRECT_URL'] = old_success
  end

  let(:redirect_target) { 'https://ikeya.by/profile/orders' }
  let(:completion_result) { :paid }

  before do
    allow(WebpayPaymentCompletionService).to receive(:complete_for_order_with_transaction!)
      .and_return(completion_result)
  end

  shared_examples 'payment success handler' do |path|
    it 'redirects to storefront success page and preserves webpay params' do
      get path, params: { wsb_order_num: '12345', wsb_tid: 'abc' }

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to('https://ikeya.by/profile/orders?wsb_order_num=12345&wsb_tid=abc')
    end

    it 'confirms webpay payment when required params are present' do
      order = create(:order, payment_order_number: 'ORDER-42', status: :created, payment_method: 'card')

      get path, params: { wsb_order_num: 'ORDER-42', wsb_tid: 'TID-1' }

      expect(WebpayPaymentCompletionService).to have_received(:complete_for_order_with_transaction!).with(
        order: order,
        transaction_id: 'TID-1'
      )
    end

    context 'when redirect target already has query params' do
      let(:redirect_target) { 'https://ikeya.by/profile/orders?tab=active' }

      it 'appends webpay params with ampersand' do
        get path, params: { wsb_tid: 'abc' }

        expect(response).to redirect_to('https://ikeya.by/profile/orders?tab=active&wsb_tid=abc')
      end
    end


    context 'when legacy WEBPAY_SUCCESS_REDIRECT_URL points to removed /account/orders route' do
      let(:redirect_target) { 'https://ikeya.by/account/orders' }

      it 'rewrites redirect to current storefront profile orders route' do
        get path, params: { wsb_tid: 'abc' }

        expect(response).to redirect_to('https://ikeya.by/profile/orders?wsb_tid=abc')
      end
    end

    context 'when legacy WEBPAY_SUCCESS_REDIRECT_URL points to removed /account/orders/:id route' do
      let(:redirect_target) { 'https://ikeya.by/account/orders/32618629/' }

      it 'rewrites redirect to current storefront profile order route' do
        get path, params: { wsb_tid: 'abc' }

        expect(response).to redirect_to('https://ikeya.by/profile/orders/32618629?wsb_tid=abc')
      end
    end
  end

  describe 'GET /payment/success' do
    include_examples 'payment success handler', '/payment/success'
  end

  describe 'GET /api/v1/payment/success' do
    include_examples 'payment success handler', '/api/v1/payment/success'
  end
end
