require 'rails_helper'

RSpec.describe 'Public Return Requests API', type: :request do
  let(:user) { create(:user) }
  let!(:order) { create(:order, user: user, public_uid: '1234567') }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}" } }

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

    it 'returns 422 when order number format is invalid' do
      post '/api/v1/return_requests', params: payload.merge(order_number: 'fewf'), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('6–8 цифр')
    end

    it 'maps compensation_method values from the storefront form' do
      post '/api/v1/return_requests',
           params: payload.merge(compensation_method: 'обмен', compensation_type: nil),
           as: :json

      expect(response).to have_http_status(:created)
      expect(ReturnRequest.last.compensation_type).to eq('exchange')
    end
  end

  describe 'POST /api/v1/account/returns without JWT' do
    it 'creates a return request (storefront modal uses this URL)' do
      post '/api/v1/account/returns',
           params: {
             order_id: order.public_uid,
             reason: 'damaged',
             comment: "test\nКомпенсация: возврат"
           },
           as: :json

      expect(response).to have_http_status(:created)
      expect(ReturnRequest.last.compensation_type).to eq('refund')
    end

    it 'does not require Authorization header' do
      post '/api/v1/account/returns',
           params: { order_id: '9999999', reason: 'damaged' },
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)['error']).not_to eq('Не авторизован')
    end

    it 'returns 422 for invalid order_id when authorized' do
      post '/api/v1/account/returns',
           params: { order_id: 'fewf', reason: 'wrong', comment: 'Компенсация: возврат' },
           headers: auth_headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('6–8 цифр')
    end
  end
end
