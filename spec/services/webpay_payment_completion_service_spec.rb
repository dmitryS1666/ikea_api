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
end
