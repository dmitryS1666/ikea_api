# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailTemplates::OrderItemsBuilder do
  let(:user) { create(:user) }
  let(:order) do
    create(
      :order,
      user: user,
      checkout_draft: false,
      total_amount: 192.55,
      delivery_price: 56.0,
      discount_amount: 0.0
    )
  end

  before do
    create(:order_item, order: order, product_sku: "SKU-1", quantity: 2, price: 50.0)
    create(:order_item, order: order, product_sku: "SKU-2", quantity: 1, price: 92.55)
  end

  it "uses persisted order totals for finalized orders" do
    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      totals: {
        subtotal_new_byn: "0.00",
        discount_total_byn: "30.00",
        final_total_byn: "0.00",
        customs_total_byn: "0.00"
      },
      items: []
    )

    totals = described_class.call(order)[:totals_html]

    expect(totals[:items_total]).to eq("192,55 р.")
    expect(totals[:grand_total]).to eq("192,55 р.")
    expect(totals[:discount_row]).to eq("")
    expect(totals[:customs_total]).to be_nil
  end
end
