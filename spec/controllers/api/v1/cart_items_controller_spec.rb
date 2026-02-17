require 'rails_helper'

RSpec.describe Api::V1::CartItemsController, type: :controller do
  let!(:product) { Product.create!(sku: '123.456.78', name: 'Test Product', price: 100, weight: 1.0) }
  
  describe 'POST #create' do
    it 'adds exactly 1 item to the cart when quantity 1 is requested' do
      expect {
        post :create, params: { sku: product.sku, quantity: 1 }
      }.to change(CartItem, :count).by(1)
      
      expect(CartItem.last.quantity).to eq(1)
    end

    it 'increments quantity correctly when adding the same item twice' do
      post :create, params: { sku: product.sku, quantity: 1 }
      token = JSON.parse(response.body)['cart']['token']
      expect(CartItem.last.quantity).to eq(1)

      post :create, params: { sku: product.sku, quantity: 1, cart_token: token }
      expect(CartItem.last.quantity).to eq(2)
    end
  end
end
