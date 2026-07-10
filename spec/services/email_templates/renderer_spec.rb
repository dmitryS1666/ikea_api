# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailTemplates::Renderer do
  let(:user) { create(:user, username: "Иван", first_name: "Иван") }
  let(:order) { create(:order, user: user, public_uid: "7654321") }

  before do
    create(:order_item, order: order, product_sku: "123", quantity: 1, price: 10.0)
  end

  it "renders order_created template with user name and order number" do
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
end
