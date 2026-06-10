require 'rails_helper'

RSpec.describe 'Order Payment Timer', type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) { create(:product, sku: "SKU123", quantity: 10, price: 100, local_images: ["/images/products/order-item.webp"]) }
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
        delivery_type: 'ikeya_delivery',
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
      expect(expiration).to be <= 21.minutes.from_now
    end
  end

  describe 'GET /api/v1/account/orders/:id' do
    let!(:order) { create(:order, user: user, status: :created) }

    it 'returns order status and payment expiration' do
      get "/api/v1/account/orders/#{order.id}", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      attributes = json['data']['attributes']

      expect(json['data']['id']).to eq(order.public_uid)
      expect(attributes).not_to have_key('id')
      expect(attributes['public_uid']).to eq(order.public_uid)
      expect(attributes).to have_key('payment_expires_at')
      expect(attributes).to have_key('payment_expired')
      expect(attributes['payment_expired']).to be false
    end

    it 'resolves the same order by public_uid in the path' do
      get "/api/v1/account/orders/#{order.public_uid}", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['id']).to eq(order.public_uid)
    end

    it 'returns Europost track number and tracking info' do
      order.update!(
        track_number: 'BY080027046773',
        tracking_info: { 'europost_create' => { 'status' => 'created' } }
      )

      get "/api/v1/account/orders/#{order.id}", headers: headers

      expect(response).to have_http_status(:ok)
      attrs = JSON.parse(response.body).dig('data', 'attributes')
      expect(attrs['track_number']).to eq('BY080027046773')
      expect(attrs['tracking_info']).to eq('europost_create' => { 'status' => 'created' })
    end


    it 'returns order item image_url in included data' do
      create(:order_item, order: order, product_sku: product.sku, quantity: 1, price: 100)

      get "/api/v1/account/orders/#{order.id}", headers: headers

      expect(response).to have_http_status(:ok)
      included_item = JSON.parse(response.body)['included'].find { |item| item['type'] == 'order_item' }
      expect(included_item.dig('attributes', 'image_url')).to eq('/images/products/order-item.webp')
    end

    it 'marks order as expired when time passes' do
      order.update!(payment_expires_at: 1.minute.ago)
      
      get "/api/v1/account/orders/#{order.id}", headers: headers
      
      json = JSON.parse(response.body)
      expect(json['data']['attributes']['payment_expired']).to be true
    end
  end

  describe 'GET /api/v1/payment_links/:id' do
    it 'expires payment link after 20 minutes' do
      order = create(:order, user: user, payment_link_token: 'expired-token')
      order.update!(payment_expires_at: 21.minutes.ago)

      get "/api/v1/payment_links/#{order.id}", params: { token: 'expired-token' }

      expect(response).to have_http_status(:gone)
    end
  end
end
