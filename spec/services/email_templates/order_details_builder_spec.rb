# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailTemplates::OrderDetailsBuilder do
  let(:order) do
    build(
      :order,
      delivery_type: DeliveryTypeNormalizer::COURIER,
      payment_method: "card",
      status: :received_poland,
      webpay_paid_at: Time.current,
      address_json: {
        "delivery" => {
          "address" => {
            "city" => "Минск",
            "street" => "ул. Независимости",
            "house" => "10"
          }
        },
        "services" => ["furniture_assembly"]
      }
    )
  end

  it "builds delivery, payment and services details" do
    details = described_class.call(order, template_key: :received_poland)

    expect(details[:delivery_address]).to include("Минск")
    expect(details[:delivery_subtitle]).to eq("Курьерская доставка")
    expect(details[:delivery_icon_url]).to eq(described_class::EUROPOST_DELIVERY_ICON_URL)
    expect(details[:payment_method_label]).to eq("Оплата картой онлайн")
    expect(details[:payment_status_label]).to eq("Оплачено")
    expect(details[:payment_status_class]).to eq("payment-status-green")
    expect(details[:service_items_html]).to include("Сборка мебели")
    expect(details[:services_present]).to be(true)
  end

  it "uses Europost icon for pickup and courier, IKEYA icon for ikeya delivery" do
    order.delivery_type = DeliveryTypeNormalizer::EUROPOST_PICKUP
    expect(described_class.call(order, template_key: :order_created)[:delivery_icon_url])
      .to eq(described_class::EUROPOST_DELIVERY_ICON_URL)

    order.delivery_type = DeliveryTypeNormalizer::COURIER
    expect(described_class.call(order, template_key: :order_created)[:delivery_icon_url])
      .to eq(described_class::EUROPOST_DELIVERY_ICON_URL)

    order.delivery_type = DeliveryTypeNormalizer::IKEYA_DELIVERY
    expect(described_class.call(order, template_key: :order_created)[:delivery_icon_url])
      .to eq(described_class::IKEYA_DELIVERY_ICON_URL)
  end

  it "marks awaiting payment templates as unpaid" do
    order.status = :processing
    order.webpay_paid_at = nil

    details = described_class.call(order, template_key: :order_awaiting_payment)

    expect(details[:payment_status_label]).to eq("Ожидает оплаты")
    expect(details[:payment_status_class]).to eq("payment-status-red")
  end
end
