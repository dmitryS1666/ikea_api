# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailTemplates::Renderer do
  let(:user) { create(:user, username: "Иван", first_name: "Иван") }
  let(:order) { create(:order, user: user, public_uid: "7654321") }

  before do
    create(:order_item, order: order, product_sku: "123", quantity: 1, price: 10.0)
    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      items: [
        {
          sku: "123",
          quantity: 1,
          pricing: {
            unit_price_new_byn: "10.00",
            line_total_new_byn: "10.00"
          }
        }
      ],
      totals: {
        subtotal_new_byn: "10.00",
        delivery_to_belarus_byn: "0.00",
        discount_total_byn: "0.00",
        final_total_byn: "10.00",
        customs_total_byn: "0.00"
      }
    )
  end

  it "renders order_created template with user name and order number" do
    order.update!(full_name: "Иван")

    html = described_class.render(:order_created, order: order, user: user)

    expect(html).to include("Иван")
    expect(html).to include("№7654321")
    expect(html).to include('href="https://ikeya.by/profile/orders/7654321"')
    expect(html).not_to include("/account/orders")
    expect(html).not_to include("№1234567")
    expect(html).not_to match(/>\s*Имя\s*</)
  end

  it "renders order_awaiting_payment totals when template spans have inline styles" do
    order.update!(
      checkout_draft: false,
      total_amount: 248.55,
      delivery_price: 56.0,
      discount_amount: 0.0,
      full_name: "Позняк Татьяна"
    )
    create(:order_item, order: order, product_sku: "456", quantity: 5, price: 38.51)

    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      items: [
        {
          sku: "123",
          quantity: 1,
          pricing: {
            unit_price_new_byn: "10.00",
            line_total_new_byn: "10.00"
          }
        },
        {
          sku: "456",
          quantity: 5,
          pricing: {
            unit_price_new_byn: "38.51",
            line_total_new_byn: "192.55"
          }
        }
      ],
      totals: {
        subtotal_new_byn: "202.55",
        delivery_to_belarus_byn: "56.00",
        discount_total_byn: "0.00",
        final_total_byn: "248.55",
        customs_total_byn: "0.00"
      }
    )

    html = described_class.render(:order_awaiting_payment, order: order.reload, user: user)

    expect(html).to include("6 товаров")
    expect(html).to include("202,55 р.")
    expect(html).to include("248,55 р.")
    expect(html).not_to include("2 430.93")
    expect(html).not_to include("2 556.93")
    expect(html).not_to include("Скидка по промокоду")
    expect(html).not_to include("≈65")
  end

  it "maps paid status to order_placed template" do
    expect(described_class.template_for_status("paid")).to eq(:order_placed)
    expect(described_class.template_for_status("shipped")).to eq(:shipped_to_pvz)
    expect(described_class.template_for_status("cancelled")).to eq(:order_cancelled)
  end

  it "injects verification URL for email_changed status button" do
    verify_url = "https://ikeya.by/account/verify-email?token=abc123"

    html = described_class.render(:email_changed, verify_email_url: verify_url)

    expect(html).to include("href=\"#{verify_url}\"")
    expect(html).not_to include("href=\"#\" class=\"status-btn\"")
  end

  it "links repeat order button to cart for cancelled orders" do
    html = described_class.render(:order_cancelled, order: order, user: user)

    expect(html).to include("href=\"https://ikeya.by/cart\"")
    expect(html).not_to include("href=\"https://ikeya.by/profile/orders\" class=\"status-btn\"")
  end

  it "links personal account info box to profile orders list" do
    html = described_class.render(:order_placed, order: order, user: user)

    expect(html).to include("href=\"https://ikeya.by/profile/orders\"")
    expect(html).not_to include("href=\"https://ikeya.by/profile/orders/7654321\" class=\"check-link\"")
  end

  it "renders received_poland template with order totals and delivery details" do
    order.update!(
      checkout_draft: false,
      total_amount: 348.59,
      delivery_price: 56.0,
      discount_amount: 30.0,
      delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
      payment_method: "card",
      full_name: "Позняк Татьяна",
      address_json: {
        "delivery" => {
          "pickup_point" => {
            "name" => "ПВЗ Марьина Горка",
            "city" => "Марьина Горка",
            "address" => "ул. Новая Заря, 6"
          }
        },
        "services" => %w[furniture_delivery furniture_assembly]
      }
    )
    create(:order_item, order: order, product_sku: "789", quantity: 2, price: 93.66)
    order.update_column(:status, Order.statuses[:received_poland])

    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      items: [
        {
          sku: "123",
          quantity: 1,
          pricing: { unit_price_new_byn: "10.00", line_total_new_byn: "10.00" }
        },
        {
          sku: "789",
          quantity: 2,
          pricing: { unit_price_new_byn: "93.66", line_total_new_byn: "187.32" }
        }
      ],
      totals: {
        subtotal_new_byn: "197.32",
        delivery_to_belarus_byn: "56.00",
        discount_total_byn: "30.00",
        final_total_byn: "348.59",
        customs_total_byn: "0.00"
      }
    )

    html = described_class.render(:received_poland, order: order.reload, user: user)

    expect(html).to include("Татьяна")
    expect(html).to include("№#{order.public_uid}")
    expect(html).to include("3 товара")
    expect(html).to include("197,32 р.")
    expect(html).to include("348,59 р.")
    expect(html).not_to include("2 430.93")
    expect(html).not_to include("2 556.93")
    expect(html).not_to include("NATTSLÄNDA")
    expect(html).not_to include("Автолайт")
    expect(html).to include("Европочта")
    expect(html).to include("Оплата картой онлайн")
    expect(html).to include("Оплачено")
    expect(html).to include("Доставка мебели")
    expect(html).to include("Сборка мебели")
    expect(html).not_to include("Подъём и занос мебели")
  end

  it "renders shipped_to_pvz template with order totals and delivery details" do
    order.update!(
      checkout_draft: false,
      total_amount: 348.59,
      delivery_price: 56.0,
      discount_amount: 30.0,
      delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
      payment_method: "card",
      full_name: "Позняк Татьяна",
      address_json: {
        "delivery" => {
          "pickup_point" => {
            "name" => "ПВЗ Марьина Горка",
            "city" => "Марьина Горка",
            "address" => "ул. Новая Заря, 6"
          }
        }
      }
    )
    create(:order_item, order: order, product_sku: "789", quantity: 2, price: 93.66)
    order.update_column(:status, Order.statuses[:shipped])

    allow(CheckoutPricingPresenter).to receive(:for_order).and_return(
      items: [
        {
          sku: "123",
          quantity: 1,
          pricing: { unit_price_new_byn: "10.00", line_total_new_byn: "10.00" }
        },
        {
          sku: "789",
          quantity: 2,
          pricing: { unit_price_new_byn: "93.66", line_total_new_byn: "187.32" }
        }
      ],
      totals: {
        subtotal_new_byn: "197.32",
        delivery_to_belarus_byn: "56.00",
        discount_total_byn: "0.00",
        final_total_byn: "348.59",
        customs_total_byn: "0.00"
      }
    )

    html = described_class.render(:shipped_to_pvz, order: order.reload, user: user)

    expect(html).to include("Ваш заказ в доставке на")
    expect(html).to include("Татьяна")
    expect(html).to include("№#{order.public_uid}")
    expect(html).to include("3 товара")
    expect(html).to include("197,32 р.")
    expect(html).to include("348,59 р.")
    expect(html).not_to include("2 430.93")
    expect(html).not_to include("NATTSLÄNDA")
    expect(html).not_to include("Минская обл.")
    expect(html).to include("ПВЗ Марьина Горка")
    expect(html).to include("Европочта")
    expect(html).to include("Оплата картой онлайн")
    expect(html).to include("Оплачено")
    expect(html).not_to include("Подъём и занос мебели")
  end
end
