require "rails_helper"

RSpec.describe PolandTracks::ExportService do
  include ActiveJob::TestHelper

  around do |example|
    keys = %w[POLAND_TRACKS_ENABLED POLAND_TRACKS_API_KEY]
    previous = keys.to_h { |key| [key, ENV[key]] }
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    ENV["POLAND_TRACKS_API_KEY"] = "test-key"
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:user) do
    create(:user, first_name: "Иван", last_name: "Иванов", middle_name: "Иванович",
                  dob: Date.new(1990, 1, 1), country_code: "RB", region: "Минская", city: "Минск",
                  street: "Ленина", house: "1", building: "2", apartment: "10", postcode: "220000",
                  encrypted_passport_json: {
                    passport_number: "MP1234567", issued_at: "2015-01-01",
                    issued_by: "РОВД", id_number: "1234567A123AB1"
                  }.to_json)
  end
  let(:product) { create(:product, price: 99.99, name_ru: "Стеллаж KALLAX", url: "https://www.ikea.com/pl/pl/p/kallax-123/") }
  let(:order) do
    create(:order, user: user, status: :created, track_number: "BY000000000BY",
                   address_json: { "pickup_point_id" => "70130090" })
  end
  let!(:item) { create(:order_item, order: order, product_sku: product.sku, price: 321.45, quantity: 2) }
  let(:export) do
    order.update!(status: :paid, webpay_paid_at: Time.current)
    PolandTrackExport.find_by!(order_id: order.id)
  end
  let(:remote_response) do
    { "id" => 1001, "code" => "IKEYABY-26-09-#{order.public_uid}", "shop_number" => "000001001PL",
      "recipient_id" => 55, "cdek_number" => "BY000000000BY", "nomerikea" => order.public_uid }
  end

  before do
    # Keep order callbacks active; isolate unrelated outbound notifications.
    allow(TelegramService).to receive(:send_message).and_return(nil)
    allow(CrmSyncJob).to receive(:perform_later)
    allow(UpdateOrderTrackingInfoJob).to receive(:perform_later)
    allow(ReindexProductFiltersJob).to receive(:perform_later)
  end

  def stub_create(status: 201, body: remote_response.to_json)
    stub_request(:post, PolandTracks::Client::ENDPOINT).to_return(status: status, body: body)
  end

  it "uses the Amo deal number, provider PVZ ID and PLN snapshot, then stores the 201 response" do
    request = stub_create
    described_class.call(export)
    expect(export.reload.state).to eq("succeeded")
    expect(export.remote_response).to eq(remote_response)
    expect(request.with do |req|
      payload = JSON.parse(req.body)
      expect(req.headers["Authorization"]).to eq("Bearer test-key")
      expect(payload).to include("delivery_type" => 1, "weight" => "1000", "nomerikea" => order.public_uid,
                                 "pvz" => 70130090, "europost_track" => order.track_number)
      expect(payload["items"].first).to include("count" => 2, "price" => 99.99, "link" => product.url)
      expect(payload["recipient"]).to include("passport_serial" => "MP", "passport_number" => "1234567",
                                             "passport_date" => "01.01.2015", "birthdate" => "01.01.1990",
                                             "building" => "1", "corpus" => "2", "index" => "220000")
      true
    end).to have_been_requested.once
  end

  def courier_address
    { "delivery" => { "address" => { "city" => "Минск", "street" => "Ленина", "house" => "1", "apartment" => "10" } } }
  end

  it "sends Europost courier with type 4, delivery address and track, without a pvz key" do
    order.update!(delivery_type: "courier", address_json: courier_address)
    request = stub_create
    described_class.call(export)
    expect(export.reload.state).to eq("succeeded")
    expect(request.with do |req|
      data = JSON.parse(req.body)
      expect(data).to include("delivery_type" => 4, "weight" => "1000", "europost_track" => order.track_number,
                             "delivery_address" => "Минск, Ленина, д. 1, кв. 10")
      expect(data).not_to have_key("pvz")
      true
    end).to have_been_requested.once
  end

  it "sends IKEYA courier with type 5 immediately without Europost track or pvz" do
    order.update!(delivery_type: "ikeya_delivery", track_number: nil, address_json: courier_address)
    request = stub_create(body: remote_response.merge("cdek_number" => nil).to_json)
    described_class.call(export)
    expect(export.reload.state).to eq("succeeded")
    expect(request.with do |req|
      data = JSON.parse(req.body)
      expect(data).to include("delivery_type" => 5, "weight" => "1000",
                             "delivery_address" => "Минск, Ленина, д. 1, кв. 10")
      expect(data.keys.take(2)).to eq(%w[delivery_type weight])
      expect(data).not_to have_key("europost_track")
      expect(data).not_to have_key("pvz")
      true
    end).to have_been_requested.once
  end

  it "does not leak a previously assigned Europost track into IKEYA delivery" do
    order.update!(delivery_type: "ikeya_delivery", address_json: courier_address)
    request = stub_create(body: remote_response.except("cdek_number").to_json)
    described_class.call(export)
    expect(export.reload.state).to eq("succeeded")
    expect(request.with { |req| !JSON.parse(req.body).key?("europost_track") }).to have_been_requested.once
  end

  %w[courier ikeya_delivery].each do |delivery_type|
    it "blocks #{delivery_type} without a complete delivery address, without using registration address" do
      order.update!(delivery_type: delivery_type, address_json: {})
      expect(PolandTracks::Client).not_to receive(:create!)
      described_class.call(export)
      expect(export.reload.state).to eq("blocked")
      expect(export.last_error).to include("delivery_address")
    end
  end

  it "keeps the courier delivery address from payment if the order address later changes" do
    order.update!(delivery_type: "courier", address_json: courier_address)
    current = export
    order.update!(address_json: { "delivery" => { "address" => { "city" => "Гомель", "street" => "Другая", "house" => "9" } } })
    expect(PolandTracks::Payload.for_export(current)["delivery_address"]).to eq("Минск, Ленина, д. 1, кв. 10")
  end

  it "requires an explicit review when the delivery type changes after payment" do
    current = export
    order.update!(delivery_type: "ikeya_delivery", address_json: courier_address)
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(current)
    expect(current.reload.state).to eq("blocked")
    expect(current.last_error).to include("Delivery type changed")
  end

  it "does not capture unknown delivery methods" do
    order.update!(delivery_type: "unknown", status: :paid)
    expect(PolandTrackExport.where(order: order)).not_to exist
  end

  it "does not capture an unpaid or cancelled order" do
    expect(PolandTrackExport.where(order: order)).not_to exist
    order.update!(status: :cancelled)
    expect(PolandTrackExport.where(order: order)).not_to exist
  end

  it "does not capture checkout drafts" do
    order.update!(checkout_draft: true, status: :paid)
    expect(PolandTrackExport.where(order: order)).not_to exist
  end

  it "rolls back the export together with payment" do
    Order.transaction do
      order.update!(status: :paid)
      raise ActiveRecord::Rollback
    end
    expect(PolandTrackExport.where(order_id: order.id)).not_to exist
    expect(order.reload).to be_created
  end

  it "does not create another export on a repeated paid transition" do
    first = export
    order.update!(status: :processing)
    order.update!(status: :paid)
    expect(PolandTrackExport.where(order: order).pluck(:id)).to eq([first.id])
  end

  it "enforces one outbox record per order at the database level" do
    current = export
    expect do
      PolandTrackExport.transaction(requires_new: true) do
        PolandTrackExport.create!(order: order, payload_json: current.payload_json)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "waits for Europost without making an HTTP request" do
    order.update!(track_number: nil)
    current = export
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(current)
    expect(current.reload.state).to eq("pending")
    expect(current.attempts).to eq(0)
    expect(current.last_error).to include("Waiting")
  end

  it "sends when the awaited Europost track appears" do
    order.update!(track_number: nil)
    current = export
    described_class.call(current)
    order.update!(track_number: "BY000000000BY")
    request = stub_create
    described_class.call(current)
    expect(current.reload.state).to eq("succeeded")
    expect(request).to have_been_requested.once
  end

  it "queues the existing export when Europost writes the track" do
    order.update!(track_number: nil)
    current = export
    clear_enqueued_jobs
    expect { order.update!(track_number: "BY000000000BY") }
      .to have_enqueued_job(PolandTrackExportJob).with(current.id)
  end

  it "does not lose the committed export if Redis cannot enqueue" do
    allow(PolandTrackExportJob).to receive(:perform_later).and_raise(IOError, "redis unavailable")
    expect { export }.not_to raise_error
    expect(PolandTrackExport.where(order: order, state: "pending")).to exist
  end

  it "does not POST twice for repeated jobs" do
    request = stub_create
    current = export
    2.times { described_class.call(PolandTrackExport.find(current.id)) }
    expect(request).to have_been_requested.once
  end

  it "commits the claim before HTTP and rejects a second worker while the first is sending" do
    current = export
    allow(PolandTracks::Client).to receive(:create!) do
      expect(current.reload.state).to eq("sending")
      described_class.call(PolandTrackExport.find(current.id))
      remote_response
    end
    described_class.call(current)
    expect(PolandTracks::Client).to have_received(:create!).once
    expect(current.reload.state).to eq("succeeded")
  end

  it "holds a timeout for reconciliation without automatic retry" do
    request = stub_request(:post, PolandTracks::Client::ENDPOINT).to_timeout
    current = export
    2.times { described_class.call(current) }
    expect(current.reload.state).to eq("uncertain")
    expect(request).to have_been_requested.once
    expect { current.retry_blocked! }.to raise_error(ArgumentError)
  end

  [500, 409, 429, 302].each do |status|
    it "requires reconciliation for HTTP #{status}" do
      request = stub_create(status: status, body: "sensitive upstream body")
      described_class.call(export)
      expect(export.reload.state).to eq("uncertain")
      expect(export.last_error).not_to include("sensitive")
      expect(request).to have_been_requested.once
    end
  end

  [401, 422].each do |status|
    it "blocks HTTP #{status} without exposing upstream personal data" do
      stub_create(status: status, body: '{"passport_number":"secret-passport"}')
      described_class.call(export)
      expect(export.reload.state).to eq("blocked")
      expected = status == 422 ? "HTTP 422; validation=unrecognized_response" : "HTTP #{status}"
      expect(export.last_error).to eq(expected)
      expect(export.remote_response).to eq({})
    end
  end

  it "does not consider an incomplete 201 response successful" do
    stub_create(body: '{"id":1001}')
    described_class.call(export)
    expect(export.reload.state).to eq("uncertain")
  end

  it "does not consider a 201 for a different order successful" do
    stub_create(body: remote_response.merge("nomerikea" => "other").to_json)
    described_class.call(export)
    expect(export.reload.state).to eq("uncertain")
  end

  it "sends without email and records success only when the API accepts it" do
    user.update_columns(email: nil)
    request = stub_create.with { |req| !JSON.parse(req.body).fetch("recipient").key?("email") }
    current = export
    described_class.call(current)
    expect(current.reload.state).to eq("succeeded")
    expect(current.remote_response).to eq(remote_response)
    expect(request).to have_been_requested.once
  end

  it "keeps an email-less request blocked after 422 without an automatic second POST" do
    user.update_columns(email: nil)
    request = stub_create(status: 422, body: '{"email":"required","passport_number":"secret"}')
      .with { |req| !JSON.parse(req.body).fetch("recipient").key?("email") }
    current = export
    described_class.call(current)
    described_class.call(current)
    expect(current.reload.state).to eq("blocked")
    expect(current.last_error).to eq("HTTP 422; validation=unrecognized_response")
    expect(current.attempts).to eq(1)
    expect(current.remote_response).to eq({})
    expect(request).to have_been_requested.once
  end

  it "stores safe 422 validation details and makes no automatic repeat request" do
    body = { errors: { "recipient.email" => ["The recipient.email field is required."],
                       "recipient.iin" => ["secret-passport-value"],
                       "items.0.price" => [{ code: "min", input: "private" }],
                       "private-key-in-field" => ["secret"] }, input: "secret-passport-value" }
    request = stub_create(status: 422, body: body.to_json)
    current = export
    described_class.call(current)
    described_class.call(current)
    expect(current.reload.state).to eq("blocked")
    expect(current.last_error).to eq("HTTP 422; fields=recipient.email(required),recipient.iin(details_redacted),items.0.price(out_of_range)")
    expect(current.remote_response).to eq({})
    expect(current.attempts).to eq(1)
    expect(request).to have_been_requested.once
  end

  it "blocks missing recipient fields while keeping payment successful" do
    user.update!(postcode: nil)
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(export)
    expect(order.reload).to be_paid
    expect(export.reload.state).to eq("blocked")
    expect(export.last_error).to include("recipient.index")
  end

  it "can retry a blocked record after profile correction" do
    user.update!(postcode: nil)
    current = export
    described_class.call(current)
    user.update!(postcode: "220000")
    current.retry_blocked!
    request = stub_create
    described_class.call(current)
    expect(current.reload.state).to eq("succeeded")
    expect(request).to have_been_requested.once
  end

  it "does not send after cancellation" do
    current = export
    order.update!(status: :cancelled)
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(current)
    expect(current.reload.state).to eq("cancelled")
  end

  it "does not send after a refund recorded after the export was captured" do
    current = export
    order.finance_entry.update!(payment_status: "refunded")
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(current)
    expect(current.reload.state).to eq("cancelled")
  end

  it "preserves recipient and goods snapshots when the profile or catalog changes" do
    current = export
    product.update!(price: 777, url: "https://example.com/changed")
    user.update!(last_name: "Другая", postcode: "000000")
    payload = PolandTracks::Payload.for_export(current)
    expect(payload["recipient"]["last_name"]).to eq("Иванов")
    expect(payload["items"].first["price"]).to eq(99.99)
    expect(payload["items"].first["link"]).to include("ikea.com")
  end

  it "encrypts the passport snapshot at rest" do
    current = export
    raw = PolandTrackExport.connection.select_value("SELECT payload_json FROM poland_track_exports WHERE id = #{current.id.to_i}")
    expect(raw).not_to include("1234567A123AB1", "Иванов")
    expect(JSON.parse(current.reload.payload_json).dig("recipient", "iin")).to eq("1234567A123AB1")
  end

  it "never substitutes BYN or a current catalog price for a missing historical PLN snapshot" do
    item.update_columns(poland_price_pln: nil)
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(export)
    expect(export.reload.state).to eq("blocked")
    expect(export.last_error).to include("PLN snapshot")
  end

  it "does not POST when disabled" do
    current = export
    ENV["POLAND_TRACKS_ENABLED"] = "false"
    expect(PolandTracks::Client).not_to receive(:create!)
    described_class.call(current)
    expect(current.reload.state).to eq("pending")
  end

  it "blocks a missing API key before any HTTP attempt" do
    ENV.delete("POLAND_TRACKS_API_KEY")
    described_class.call(export)
    expect(export.reload.state).to eq("blocked")
    expect(export.attempts).to eq(0)
  end

  it "dispatches pending rows and holds abandoned sending rows for reconciliation" do
    current = export
    clear_enqueued_jobs
    expect { DispatchPolandTrackExportsJob.perform_now }.to have_enqueued_job(PolandTrackExportJob).with(current.id)
    current.update!(state: "sending", last_attempt_at: 11.minutes.ago)
    clear_enqueued_jobs
    expect { DispatchPolandTrackExportsJob.perform_now }.not_to have_enqueued_job(PolandTrackExportJob)
    expect(current.reload.state).to eq("uncertain")
  end
end
