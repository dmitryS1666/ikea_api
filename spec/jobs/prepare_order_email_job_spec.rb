# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrepareOrderEmailJob, type: :job do
  include ActiveJob::TestHelper
  let(:user) { create(:user, email: "customer@example.com", username: "Татьяна") }
  let(:order) do
    create(
      :order,
      user: user,
      checkout_draft: false,
      public_uid: "622583",
      full_name: "Позняк Татьяна Николаевна",
      total_amount: 210.93,
      delivery_price: 56.0,
      discount_amount: 0.0,
      payment_method: "card",
      payment_url: "https://payment.example/pay/622583",
      delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
      address_json: {
        "delivery" => {
          "pickup_point" => {
            "name" => "ПВЗ Марьина Горка",
            "city" => "Марьина Горка",
            "address" => "ул. Новая Заря, 6"
          }
        }
      },
      pricing_snapshot: {
        "version" => 1,
        "items_count" => 2,
        "items_total_byn" => "154.93",
        "delivery_total_byn" => "56.00",
        "discount_total_byn" => "0.00",
        "grand_total_byn" => "210.93",
        "customs_total_byn" => "0.00"
      }
    )
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    create(
      :order_item,
      order: order,
      product_sku: "SKU-SNAPSHOT",
      quantity: 2,
      price: 77.465,
      name_snapshot: "Коврик для ванной, розовый, 50x80 см",
      description_snapshot: "Ширина: 50 см, Длина: 80 см"
    )
    allow(SendpulseEmailJob).to receive(:perform_later)
  end

  %w[
    order_created
    order_awaiting_payment
    received_poland
    shipped_to_pvz
    order_cancelled
  ].each do |template_key|
    it "passes complete order HTML to SendpulseEmailJob for #{template_key}" do
      described_class.perform_now(template_key: template_key, order_id: order.id)

      expect(SendpulseEmailJob).to have_received(:perform_later) do |payload|
        expect(payload[:to_email]).to eq("customer@example.com")
        expect(payload[:html]).to include("№622583")
        expect(payload[:html]).to include("Татьяна")
        expect(payload[:html]).to include("Коврик для ванной, розовый, 50x80 см")
        expect(payload[:html]).to include("2 шт.")
        expect(payload[:html]).to include("154,93 р.")
        expect(payload[:html]).to include("210,93 р.")
        expect(payload[:html]).to include("ПВЗ Марьина Горка")
        expect(payload[:html]).not_to include("NATTSLÄNDA")
        expect(payload[:html]).not_to include("2 556.93")
        expect(payload[:html]).not_to include("Скидка по промокоду")
      end
    end
  end

  it "rejects draft orders instead of sending incomplete data" do
    order.update_column(:checkout_draft, true)

    expect do
      described_class.perform_now(template_key: "order_created", order_id: order.id)
    end.to have_enqueued_job(described_class)

    expect(SendpulseEmailJob).not_to have_received(:perform_later)
  end

  it "allows the abandoned-cart template for a checkout draft" do
    queued_at = Time.current
    activity_at = 31.minutes.ago
    order.update_columns(
      checkout_draft: true,
      status: Order.statuses[:created],
      updated_at: activity_at,
      abandoned_cart_email_sent_at: queued_at
    )

    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      items: [
        {
          sku: "SKU-SNAPSHOT",
          quantity: 2,
          pricing: {
            unit_price_new_byn: "77.47",
            line_total_new_byn: "154.93"
          }
        }
      ],
      totals: {
        subtotal_new_byn: "154.93",
        delivery_to_belarus_byn: "0.00",
        discount_total_byn: "0.00",
        final_total_byn: "154.93",
        customs_total_byn: "0.00"
      }
    )

    described_class.perform_now(
      template_key: "abandoned_cart",
      order_id: order.id,
      abandoned_cart_activity_at: activity_at.iso8601(6),
      abandoned_cart_queued_at: queued_at.iso8601(6)
    )

    expect(SendpulseEmailJob).to have_received(:perform_later) do |payload|
      expect(payload[:to_email]).to eq("customer@example.com")
      expect(payload[:html]).to include("Коврик для ванной, розовый, 50x80 см")
      expect(payload[:html]).to include('href="https://ikeya.by/cart"')
      expect(payload[:html]).not_to include('href="https://ikeya.by/checkout" class="status-btn"')
    end
  end

  it "cancels a queued abandoned-cart email when the draft changed meanwhile" do
    queued_at = 1.minute.ago
    stale_activity_at = 31.minutes.ago
    order.update_columns(
      checkout_draft: true,
      status: Order.statuses[:created],
      updated_at: Time.current,
      abandoned_cart_email_sent_at: queued_at
    )

    described_class.perform_now(
      template_key: "abandoned_cart",
      order_id: order.id,
      abandoned_cart_activity_at: stale_activity_at.iso8601(6),
      abandoned_cart_queued_at: queued_at.iso8601(6)
    )

    expect(SendpulseEmailJob).not_to have_received(:perform_later)
    expect(order.reload.abandoned_cart_email_sent_at).to be_nil
  end
end
