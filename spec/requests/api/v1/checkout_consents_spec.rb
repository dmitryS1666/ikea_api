# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Checkout consents", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-CONSENT-1",
      quantity: 10,
      price: 100.0,
      weight: 10.0,
      package_volume: 0.02,
      package_dimensions: "20 x 30 x 40 cm",
      dimensions: "20 x 30 x 40 cm",
      full_attributes: {}
    )
  end

  before do
    create(:cart_item, cart: cart, product_sku: product.sku, quantity: 1)
    allow(EuropostApiService).to receive(:offices_out).and_return(
      [{ "WarehouseId" => "70130010", "WarehouseWeightLimit" => "50" }]
    )
    allow(EuropostApiService).to receive(:external_stores_for_merge).and_return([])
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(WebpayPaymentLinkService).to receive(:issue_link!)
    allow(TelegramService).to receive(:send_message)
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    LegalPage.create!(title: "ПД", slug: LegalPage::SLUG_PERSONAL_DATA, body: "x", status: :published)
    LegalPage.create!(title: "Оферта", slug: LegalPage::SLUG_PUBLIC_OFFER, body: "x", status: :published)
    LegalPage.create!(title: "Брокер", slug: LegalPage::SLUG_CUSTOMS_BROKER, body: "x", status: :published)
  end

  it "rejects checkout without offer agreement consent" do
    post "/api/v1/checkout",
         params: checkout_consents(offer_agreement_consent: false).merge(
           full_name: "User",
           phone: "375291112233",
           delivery_type: "europost_pickup",
           payment_method: "card",
           pickup_point_id: "70130010"
         ),
         headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["code"]).to eq("consent_required")
    expect(body["field"]).to eq("offer_agreement_consent")
    expect(Order.count).to eq(0)
  end

  it "allows checkout without personal data consent and stores other consents" do
    post "/api/v1/checkout",
         params: checkout_consents(personal_data_consent: false).merge(
           full_name: "User",
           phone: "375291112233",
           delivery_type: "europost_pickup",
           payment_method: "card",
           pickup_point_id: "70130010"
         ),
         headers: headers

    expect(response).to have_http_status(:created)

    order = Order.last
    expect(order.offer_agreement_consent).to be(true)
    expect(order.customs_broker_consent).to be(true)
    expect(order.personal_data_consent).to be(false)
    expect(ConsentRecord.where(order: order).count).to eq(2)
    expect(user.reload.personal_data_consent).to be(false)
  end

  it "accepts personal_data_consent from registered user on finalize without resending it" do
    user.update!(personal_data_consent: true, personal_data_consented_at: 1.day.ago)

    post "/api/v1/checkout", params: { draft: true }, headers: headers
    order = Order.last

    patch "/api/v1/checkout/#{order.id}",
          params: {
            delivery_type: "europost_pickup",
            pickup_point_id: "70130010",
            full_name: "User",
            phone: "375291112233",
            payment_method: "card"
          },
          headers: headers

    post "/api/v1/checkout/#{order.id}/finalize",
         params: {
           full_name: "User",
           phone: "375291112233",
           delivery_type: "europost_pickup",
           payment_method: "card",
           pickup_point_id: "70130010"
         },
         headers: headers

    expect(response).to have_http_status(:created)
    order.reload
    expect(order.personal_data_consent).to be(true)
    expect(order.offer_agreement_consent).to be(true)
    expect(order.customs_broker_consent).to be(true)
    expect(ConsentRecord.where(order: order).count).to eq(3)
  end
end
