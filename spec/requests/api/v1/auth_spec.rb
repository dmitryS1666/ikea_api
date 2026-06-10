require 'swagger_helper'

RSpec.describe 'api/v1/auth', type: :request do
  let(:phone_data) { { phone: '+375291234567' } }


  path '/api/v1/auth/phone/send' do
    post('send phone code') do
      tags 'Auth'
      consumes 'application/json'
      parameter name: :phone_data, in: :body, schema: {
        type: :object,
        properties: {
          phone: { type: :string, example: '79991234567' }
        },
        required: [ 'phone' ]
      }

      response(200, 'successful') do
        schema type: :object, properties: {
          message: { type: :string, example: 'Код отправлен' }
        }
        run_test!
      end

    end
  end

  path '/api/v1/auth/phone/verify' do
    post('verify phone code') do
      tags 'Auth'
      consumes 'application/json'
      parameter name: :verify_data, in: :body, schema: {
        type: :object,
        properties: {
          phone: { type: :string, example: '79991234567' },
          code: { type: :string, example: '1234' },
          cart_token: { type: :string, example: 'guest_token_123' }
        },
        required: %w[phone code]
      }

      response(200, 'successful login') do
        before do
          create(:user, phone: '375291234567', username: 'Existing User')
          VerificationCode.create!(
            phone: '375291234567',
            code: '1234',
            expires_at: 10.minutes.from_now
          )
          allow(CrmIntegrationService).to receive(:update_last_login).and_return(true)
        end

        let(:verify_data) { { phone: '+375291234567', code: '1234' } }

        schema type: :object, properties: {
          token: { type: :string },
          user: {
            type: :object,
            properties: {
              id: { type: :integer },
              username: { type: :string },
              phone: { type: :string },
              role: { type: :string }
            }
          },
          is_new: { type: :boolean }
        }
        run_test!
      end

      response(201, 'user created') do
        before do
          VerificationCode.create!(
            phone: '375291111111',
            code: '1234',
            expires_at: 10.minutes.from_now
          )
          allow(CrmIntegrationService).to receive(:update_last_login).and_return(true)
        end

        let(:verify_data) do
          {
            phone: '+375291111111',
            code: '1234',
            username: 'New User'
          }
        end

        run_test!
      end

      response(401, 'unauthorized') do
        let(:verify_data) { { phone: '+375299999999', code: '0000' } }

        run_test!
      end
    end
  end
end

RSpec.describe 'Phone auth cart merge', type: :request do
  let(:user) { create(:user, phone: '375291234567') }
  let!(:user_cart) { create(:cart, user: user, guest_token: 'user-token-before') }
  let!(:guest_cart) { create(:cart, user: nil, guest_token: 'guest-token-before-auth') }
  let!(:product) { create(:product, sku: 'AUTH-MERGE-SKU', quantity: 10, price: 100.0) }

  before do
    create(:cart_item, cart: guest_cart, product_sku: product.sku, quantity: 2)
    allow(PhoneAuthService).to receive(:verify_code).and_return(success: true, user: user, is_new: false)
    allow(CrmIntegrationService).to receive(:update_last_login)
  end

  it 'merges guest cart and keeps submitted cart_token usable after auth' do
    post '/api/v1/auth/phone/verify', params: {
      phone: user.phone,
      code: '1234',
      cart_token: guest_cart.guest_token
    }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json['cart_token']).to eq('guest-token-before-auth')

    user_cart.reload
    expect(user_cart.guest_token).to eq('guest-token-before-auth')
    expect(user_cart.cart_items.find_by(product_sku: product.sku).quantity).to eq(2)
  end
end
