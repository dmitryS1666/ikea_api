require 'rails_helper'

RSpec.describe 'Public Return Requests API', type: :request do
  let(:user) { create(:user) }
  let!(:order) { create(:order, user: user, public_uid: '1234567') }

  describe 'POST /api/v1/return_requests' do
    let(:payload) do
      {
        first_name: 'Иван',
        patronymic: 'Иванович',
        order_number: order.public_uid,
        phone: '+375291234567',
        email: 'ivan@example.com',
        reason: 'Товар повреждён при доставке',
        comment: 'Упаковка вмята',
        compensation_type: 'refund'
      }
    end

    it 'creates a return request for a valid order number' do
      expect do
        post '/api/v1/return_requests', params: payload, as: :json
      end.to change(ReturnRequest, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('return_request', 'order_number')).to eq(order.public_uid)
      expect(body.dig('return_request', 'status')).to eq('new')

      req = ReturnRequest.last
      expect(req.order).to eq(order)
      expect(req.user).to eq(user)
      expect(req.first_name).to eq('Иван')
      expect(req.compensation_type).to eq('refund')
    end

    it 'returns 404 when order number is unknown' do
      post '/api/v1/return_requests', params: payload.merge(order_number: '9999999'), as: :json

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)['error']).to eq('Заказ не найден')
    end

    it 'maps compensation_method values from the storefront form' do
      post '/api/v1/return_requests',
           params: payload.merge(compensation_method: 'обмен', compensation_type: nil),
           as: :json

      expect(response).to have_http_status(:created)
      expect(ReturnRequest.last.compensation_type).to eq('exchange')
    end
  end
end
