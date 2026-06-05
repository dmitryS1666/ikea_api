require "rails_helper"

RSpec.describe "Checkout delivery types", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let!(:cart) { create(:cart, user: user) }
  let!(:product) do
    create(
      :product,
      sku: "SKU-CHK-1",
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
      [
        {
          "WarehouseId" => "70130010",
          "WarehouseName" => "Отделение №1",
          "Address7Name" => "Минск",
          "Address5Name" => "Минск",
          "Address4Name" => "Монтажников",
          "Address3Name" => "2",
          "Info1" => "Режим работы: 09:00 - 21:00",
          "WarehouseWeightLimit" => "50"
        }
      ]
    )
    allow(EuropostApiService).to receive(:external_stores_for_merge).and_return([])
    allow(ExchangeRate).to receive(:fetch_or_create).and_return(double(rate_per_unit: 3.2))
    allow(CrmIntegrationService).to receive(:sync_order).and_return({ success: true })
    allow(WebpayPaymentLinkService).to receive(:issue_link!)
    allow(TelegramService).to receive(:send_message)
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  def checkout(payload)
    post "/api/v1/checkout", params: payload, headers: headers
  end

  it "rejects unsupported delivery type" do
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "unsupported",
      payment_method: "card",
      pickup_point_id: "70130010"
    )

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["error"]).to eq("Неподдерживаемый тип доставки")
    expect(body["delivery_type"]).to eq("unsupported")
    expect(body["normalized_delivery_type"]).to eq("unsupported")
  end

  it "creates order with europost_pickup" do
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    )

    expect(response).to have_http_status(:created)
    expect(Order.last.delivery_type).to eq("europost_pickup")
  end

  it "creates order with europost API warehouse id without local pickup point" do
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    )

    expect(response).to have_http_status(:created)
    pickup_snapshot = Order.last.address_json.dig("delivery", "pickup_point")
    expect(pickup_snapshot["external_id"]).to eq("70130010")
    expect(pickup_snapshot["address"]).to eq("Минск, Монтажников, 2")
  end

  it "creates order with courier and delivery_address_id" do
    address = create(:user_delivery_address, user: user)
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "courier",
      payment_method: "card",
      delivery_address_id: address.id
    )

    expect(response).to have_http_status(:created)
    expect(Order.last.delivery_type).to eq("courier")
  end

  it "creates order with ikeya_delivery when europost is unavailable" do
    product.update!(
      weight: nil,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: nil,
      full_attributes: {}
    )
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "ikeya_delivery",
      payment_method: "card",
      address: { city: "Minsk", street: "Main", house: "1" }
    )

    expect(response).to have_http_status(:created)
    expect(Order.last.delivery_type).to eq("ikeya_delivery")
  end

  it "does not create order for unavailable delivery type" do
    product.update!(
      weight: nil,
      package_volume: nil,
      package_dimensions: nil,
      dimensions: nil,
      full_attributes: {}
    )

    expect {
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "courier",
        payment_method: "card",
        address: { city: "Minsk", street: "Main", house: "1" }
      )
    }.not_to change(Order, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "saves delivery snapshot in address_json" do
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    )

    order = Order.last
    expect(order.address_json["delivery"]).to be_present
    expect(order.address_json["delivery"]["type"]).to eq("europost_pickup")
    expect(order.address_json["delivery"]["provider"]).to eq("europost")
    expect(order.address_json["delivery"]["pickup_point"]).to be_present
    expect(order.address_json["delivery"]["address"]).to be_nil
    expect(order.address_json["delivery"]["prices"]).to be_present
    # legacy keys used by existing API consumers are preserved
    expect(order.address_json["pickup_point_id"]).to eq(70130010)
    expect(order.address_json).to have_key("weight_kg")
    expect(order.address_json).to have_key("pln_total")
  end

  it "rejects europost_pickup without pickup_point_id or pickup_point payload" do
    expect {
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "europost_pickup",
        payment_method: "card"
      )
    }.not_to change(Order, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to match(/pickup_point/i)
  end

  it "rejects courier without delivery_address_id or address payload" do
    expect {
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "courier",
        payment_method: "card"
      )
    }.not_to change(Order, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to match(/delivery_address_id|address/i)
  end

  it "keeps order serializer working for account orders show" do
    address = create(:user_delivery_address, user: user)
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "courier",
      payment_method: "card",
      delivery_address_id: address.id
    )
    order = Order.last

    get "/api/v1/account/orders/#{order.id}", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "attributes", "address")).to be_present
  end

  it "enqueues client and admin sendpulse emails after successful order create" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SENDPULSE_ADMIN_NOTIFY_EMAIL").and_return("manager@example.com")

    expect do
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "europost_pickup",
        payment_method: "card",
        pickup_point_id: "70130010"
      )
    end.to change { enqueued_jobs.count { |job| job[:job] == SendpulseEmailJob } }.by(2)
  end

  it "enqueues only client sendpulse email when admin email is not set" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SENDPULSE_ADMIN_NOTIFY_EMAIL").and_return(nil)

    expect do
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "europost_pickup",
        payment_method: "card",
        pickup_point_id: "70130010"
      )
    end.to change { enqueued_jobs.count { |job| job[:job] == SendpulseEmailJob } }.by(1)
  end

  it "does not enqueue sendpulse notifications for unsuccessful order creation" do
    expect do
      checkout(
        full_name: "User",
        phone: "375291112233",
        delivery_type: "courier",
        payment_method: "card"
      )
    end.not_to change { enqueued_jobs.count { |job| job[:job] == SendpulseEmailJob } }
  end

  it "does not enqueue duplicate order-created notifications on regular order update" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SENDPULSE_ADMIN_NOTIFY_EMAIL").and_return("manager@example.com")
    checkout(
      full_name: "User",
      phone: "375291112233",
      delivery_type: "europost_pickup",
      payment_method: "card",
      pickup_point_id: "70130010"
    )
    clear_enqueued_jobs

    expect do
      Order.last.update!(phone: "375299998877")
    end.not_to change { enqueued_jobs.count { |job| job[:job] == SendpulseEmailJob } }
  end
end
