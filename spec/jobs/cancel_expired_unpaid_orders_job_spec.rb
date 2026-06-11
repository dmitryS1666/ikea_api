require 'rails_helper'

RSpec.describe CancelExpiredUnpaidOrdersJob, type: :job do
  before do
    allow(OrderNotificationService).to receive(:call)
  end

  it 'cancels expired created and processing orders' do
    created_order = create(:order, status: :created)
    processing_order = create(:order, status: :processing)
    created_order.update_column(:payment_expires_at, 5.minutes.ago)
    processing_order.update_column(:payment_expires_at, 5.minutes.ago)

    result = described_class.perform_now

    expect(result[:cancelled]).to eq(2)
    expect(created_order.reload.status).to eq('cancelled')
    expect(processing_order.reload.status).to eq('cancelled')
    expect(created_order.cancellation_reason).to eq('Истек срок оплаты заказа')
    expect(processing_order.cancellation_reason).to eq('Истек срок оплаты заказа')
  end

  it 'does not cancel paid and later orders even when payment_expires_at is in the past' do
    paid_order = create(:order, status: :paid)
    purchased_order = create(:order, status: :purchased)
    completed_order = create(:order, status: :completed)
    [paid_order, purchased_order, completed_order].each do |order|
      order.update_column(:payment_expires_at, 5.minutes.ago)
    end

    result = described_class.perform_now

    expect(result[:cancelled]).to eq(0)
    expect(paid_order.reload.status).to eq('paid')
    expect(purchased_order.reload.status).to eq('purchased')
    expect(completed_order.reload.status).to eq('completed')
  end

  it 'does not cancel orders until the configured grace period has passed' do
    processing_order = create(:order, status: :processing)
    processing_order.update_column(:payment_expires_at, 30.minutes.ago)

    result = Order.cancel_expired_unpaid!(grace_period: 1.hour)

    expect(result[:cancelled]).to eq(0)
    expect(processing_order.reload.status).to eq('processing')
  end

  it 'does not cancel checkout drafts' do
    draft_order = create(:order, status: :created, checkout_draft: true)
    draft_order.update_column(:payment_expires_at, 5.minutes.ago)

    result = described_class.perform_now

    expect(result[:cancelled]).to eq(0)
    expect(draft_order.reload.status).to eq('created')
  end
end
