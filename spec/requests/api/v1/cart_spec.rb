require 'swagger_helper'

RSpec.describe 'Cart API', type: :request do
  before do
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
  end

  path '/api/v1/cart' do
    get 'Show cart' do
      tags 'Cart'
      produces 'application/json'

      parameter name: :cart_token, in: :query, type: :string, required: false

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/cart_items' do
    delete 'Delete selected cart items or clear cart' do
      tags 'Cart'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          skus: { type: :array, items: { type: :string }, example: ['123.456.78'] },
          delete_all: { type: :boolean, example: false }
        }
      }

      response '200', 'successful' do
        let(:payload) { { delete_all: true } }

        run_test!
      end

      response '422', 'unprocessable entity' do
        let(:payload) { {} }

        run_test!
      end
    end
  end

  path '/api/v1/cart/promo/apply' do
    post 'Apply promo code' do
      tags 'Cart'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: { code: { type: :string, example: 'PROMO10' } },
        required: ['code']
      }

      response '200', 'successful' do
        before do
          PromoCode.find_or_create_by!(code: 'TESTPROMO') do |promo|
            promo.discount_type = :percent
            promo.discount_value = 10
            promo.active = true
          end
        end

        let(:payload) { { code: 'TESTPROMO' } }

        run_test!
      end

      response '422', 'unprocessable entity' do
        let(:payload) { { code: 'BADPROMO' } }

        run_test!
      end
    end
  end

  path '/api/v1/cart/summary' do
    post 'Calculate summary for selected cart items' do
      tags 'Cart'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :payload, in: :body, schema: {
        type: :object,
        properties: {
          cart_token: { type: :string },
          items: {
            type: :array,
            items: {
              type: :object,
              properties: {
                sku: { type: :string, example: '90205097' },
                quantity: { type: :integer, example: 1 }
              },
              required: %w[sku quantity]
            }
          }
        },
        required: ['items']
      }

      response '200', 'successful' do
        let!(:summary_cart) { create(:cart, guest_token: 'rswag-summary-token') }
        let!(:summary_product) { create(:product, sku: 'RSWAG-SUMMARY', quantity: 10, price: 200.0, weight: 5.0) }

        before do
          create(:cart_item, cart: summary_cart, product_sku: summary_product.sku, quantity: 2)
        end

        let(:payload) do
          {
            cart_token: summary_cart.guest_token,
            items: [{ sku: summary_product.sku, quantity: 1 }]
          }
        end

        run_test!
      end

      response '422', 'unprocessable entity' do
        let(:payload) { { items: [] } }

        run_test!
      end
    end
  end

  path '/api/v1/cart/promo/remove' do
    delete 'Remove promo code' do
      tags 'Cart'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end


RSpec.describe 'Cart partial summary contract', type: :request do
  let(:user) { create(:user) }
  let(:headers) { { 'Authorization' => "Bearer #{JwtService.encode(user_id: user.id)}" } }
  let!(:user_cart) { create(:cart, user: user) }
  let!(:guest_cart) { create(:cart, user: nil, guest_token: 'guest-summary-token') }
  let!(:product_a) { create(:product, sku: 'SUM-REQ-A', quantity: 10, price: 200.0, weight: 5.0) }
  let!(:product_b) { create(:product, sku: 'SUM-REQ-B', quantity: 10, price: 300.0, weight: 5.0) }

  before do
    create(:cart_item, cart: user_cart, product_sku: product_b.sku, quantity: 1)
    create(:cart_item, cart: guest_cart, product_sku: product_a.sku, quantity: 2)
    create(:cart_item, cart: guest_cart, product_sku: product_b.sku, quantity: 1)
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
  end

  it 'uses explicit cart_token even for authenticated user' do
    post '/api/v1/cart/summary',
         params: { cart_token: guest_cart.guest_token, items: [{ sku: product_a.sku, quantity: 1 }] },
         headers: headers

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json['items'].map { |i| i['sku'] }).to eq([product_a.sku])
  end

  it 'returns item_not_in_cart for selected SKU missing from token cart' do
    post '/api/v1/cart/summary',
         params: { cart_token: guest_cart.guest_token, items: [{ sku: 'MISSING', quantity: 1 }] },
         headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    json = JSON.parse(response.body)
    expect(json['code']).to eq('item_not_in_cart')
    expect(json['sku']).to eq('MISSING')
  end

  it 'applies promo to selected items without mutating the full cart' do
    PromoCode.create!(code: 'REQ10', discount_type: :percent, discount_value: 10, active: true)

    post '/api/v1/cart/promo/apply',
         params: { cart_token: guest_cart.guest_token, code: 'REQ10', items: [{ sku: product_a.sku, quantity: 1 }] }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json['items'].map { |i| i['sku'] }).to eq([product_a.sku])
    expect(json['discount_total_byn'].to_f).to be > 0
    expect(guest_cart.reload.promo_code).to be_nil
  end
end
