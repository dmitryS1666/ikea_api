require 'rails_helper'

RSpec.describe WebpayPaymentCompletionService do
  describe 'late payment after auto-cancel' do
    it 'does not restore a cancelled order from WebPay notification handling' do
      order = create(:order, status: :cancelled)

      result = described_class.new.send(:apply_paid!, order, 'late-transaction-id')

      expect(result).to eq(:invalid_state)
      expect(order.reload.status).to eq('cancelled')
      expect(order.webpay_transaction_id).to be_nil
      expect(order.webpay_paid_at).to be_nil
    end
  end

  describe 'cart after payment' do
    it 'removes the paid quantities and leaves the rest in the cart' do
      allow(OrderNotificationService).to receive(:call)
      user = create(:user)
      cart = create(:cart, user: user)
      create(:cart_item, cart: cart, product_sku: '90205097', quantity: 2)
      create(:cart_item, cart: cart, product_sku: '09588114', quantity: 1)
      order = create(:order, user: user, status: :processing, payment_method: 'card', total_amount: 10)
      create(:order_item, order: order, product_sku: '90205097', quantity: 1)

      result = described_class.new.send(:apply_paid!, order, 'txn-paid-1')

      expect(result).to eq(:paid)
      expect(cart.reload.cart_items.find_by(product_sku: '90205097').quantity).to eq(1)
      expect(cart.cart_items.find_by(product_sku: '09588114').quantity).to eq(1)
    end
  end
end
