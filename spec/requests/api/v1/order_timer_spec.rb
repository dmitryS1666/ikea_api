require 'rails_helper'

RSpec.describe 'Order Payment Timer', type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) { create(:product, sku: 'SKU123', quantity: 10, price: 100) }
  let!(:cart_item) { create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1) }

  before do
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(
      double(rate: 3.2, scale: 1, rate_per_unit: 3.2)
    )
    # Stub CRM sync and notifications
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(OrderNotificationService).to receive(:call)
  end

  describe 'POST /api/v1/checkout' do
    let(:params) do
      {
        full_name: 'Test User',
        phone: '375291234567',
        delivery_type: 'courier',
        payment_method: 'card',
        address: { city: 'Minsk', street: 'Main' }
      }
    end

    it 'returns order with payment timer information' do
      post '/api/v1/checkout', params: params, headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      
      expect(json['order']).to have_key('payment_expires_at')
      expect(json['order']['payment_expires_at']).not_to be_nil
      
      expiration = Time.parse(json['order']['payment_expires_at'])
      expect(expiration).to be > Time.current
      expect(expiration).to be <= 31.minutes.from_now
    end
  end

  describe 'GET /api/v1/account/orders/:id' do
    let!(:order) { create(:order, user: user, status: :created) }

    it 'returns order status and payment expiration' do
      get "/api/v1/account/orders/#{order.id}", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      attributes = json['data']['attributes']

      expect(attributes).to have_key('payment_expires_at')
      expect(attributes).to have_key('payment_expired')
      expect(attributes['payment_expired']).to be false
    end

    it 'marks order as expired when time passes' do
      order.update!(payment_expires_at: 1.minute.ago)
      
      get "/api/v1/account/orders/#{order.id}", headers: headers
      
      json = JSON.parse(response.body)
      expect(json['data']['attributes']['payment_expired']).to be true
    end
  end
end
