require 'rails_helper'

RSpec.describe 'POST /api/v1/webhooks/webpay', type: :request do
  let(:secret) { Rails.application.config.x.webpay.secret_key }

  before do
    allow(WebpayGetTransactionService).to receive(:billing_configured?).and_return(false)
    allow(WebpayGetTransactionService).to receive(:fetch)
    allow(CrmSyncJob).to receive(:perform_later)
  end

  def notify_params(attrs)
    p = attrs.stringify_keys
    payload = WebpaySignatureService.send(:notify_signing_payload, p)
    p.merge('wsb_signature' => Digest::MD5.hexdigest(payload + secret))
  end

  it 'marks order paid on valid notification' do
    order = create(:order,
                   status: :created,
                   total_amount: 100.00,
                   payment_order_number: 'ORDER-SPEC-1',
                   payment_method: 'card')

    body = notify_params(
      'batch_timestamp' => '1562591640',
      'currency_id' => 'BYN',
      'amount' => '100.00',
      'payment_method' => 'cc',
      'order_id' => '999001',
      'site_order_id' => order.payment_order_number,
      'transaction_id' => '858578101',
      'payment_type' => '4',
      'rrn' => '786755995452'
    )

    post '/api/v1/webhooks/webpay', params: body

    expect(response).to have_http_status(:ok)
    order.reload
    expect(order).to be_paid
    expect(order.webpay_transaction_id).to eq('858578101')
    expect(order.webpay_paid_at).to be_present
    expect(CrmSyncJob).to have_received(:perform_later).with('Order', order.id).once
  end

  it 'returns forbidden on bad signature' do
    order = create(:order,
                   status: :created,
                   total_amount: 50.00,
                   payment_order_number: 'ORDER-SPEC-2',
                   payment_method: 'card')

    body = notify_params(
      'batch_timestamp' => '1562591640',
      'currency_id' => 'BYN',
      'amount' => '50.00',
      'payment_method' => 'cc',
      'order_id' => '999002',
      'site_order_id' => order.payment_order_number,
      'transaction_id' => '858578102',
      'payment_type' => '4',
      'rrn' => '786755995453'
    ).merge('wsb_signature' => 'deadbeef')

    post '/api/v1/webhooks/webpay', params: body

    expect(response).to have_http_status(:forbidden)
    expect(order.reload).to be_created
  end

  it 'is idempotent for duplicate notifications' do
    order = create(:order,
                   status: :created,
                   total_amount: 10.00,
                   payment_order_number: 'ORDER-SPEC-3',
                   payment_method: 'card')

    body = notify_params(
      'batch_timestamp' => '1562591640',
      'currency_id' => 'BYN',
      'amount' => '10.00',
      'payment_method' => 'cc',
      'order_id' => '999003',
      'site_order_id' => order.payment_order_number,
      'transaction_id' => '858578103',
      'payment_type' => '1',
      'rrn' => '786755995454'
    )

    post '/api/v1/webhooks/webpay', params: body
    post '/api/v1/webhooks/webpay', params: body

    expect(response).to have_http_status(:ok)
    expect(order.reload.webpay_transaction_id).to eq('858578103')
    expect(CrmSyncJob).to have_received(:perform_later).with('Order', order.id).once
  end

  context 'when Billing API get_transaction fails' do
    before do
      allow(WebpayGetTransactionService).to receive(:billing_configured?).and_return(true)
      allow(WebpayGetTransactionService).to receive(:fetch).and_return(
        WebpayGetTransactionService::Result.new(ok: false, fields: {}, raw_xml: nil, error: 'http_500')
      )
    end

    it 'still marks order paid from signed notify' do
      order = create(:order,
                     status: :created,
                     total_amount: 25.00,
                     payment_order_number: 'ORDER-SPEC-BILLING-FAIL',
                     payment_method: 'card')

      body = notify_params(
        'batch_timestamp' => '1562591640',
        'currency_id' => 'BYN',
        'amount' => '25.00',
        'payment_method' => 'cc',
        'order_id' => '999004',
        'site_order_id' => order.payment_order_number,
        'transaction_id' => '858578104',
        'payment_type' => '4',
        'rrn' => '786755995455'
      )

      post '/api/v1/webhooks/webpay', params: body

      expect(response).to have_http_status(:ok)
      expect(order.reload).to be_paid
    end
  end
end
