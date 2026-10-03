require "rails_helper"

RSpec.describe PolandTracks::SeptemberWeightPatch do
  include ActiveJob::TestHelper

  let(:as_of) { "2026-09-27T14:08:17+03:00" }
  let(:paid_at) { Time.iso8601("2026-09-20T12:00:00+03:00") }
  let(:user) do
    create(:user, first_name: "Иван", last_name: "Иванов", country_code: "RB",
                  dob: Date.new(1990, 1, 1), region: "Минская", city: "Минск", street: "Ленина",
                  house: "1", postcode: "220000", encrypted_passport_json: {
                    passport_number: "MP1234567", issued_at: "2015-01-01",
                    issued_by: "РОВД", id_number: "1234567A123AB1"
                  }.to_json)
  end

  around do |example|
    previous = %w[POLAND_TRACKS_ENABLED POLAND_TRACKS_API_KEY].to_h { |key| [key, ENV[key]] }
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    ENV["POLAND_TRACKS_API_KEY"] = "test-key"
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before do
    allow(TelegramService).to receive(:send_message)
    allow(CrmSyncJob).to receive(:perform_later)
    allow(UpdateOrderTrackingInfoJob).to receive(:perform_later)
    allow(EuropostCreateShipmentJob).to receive(:perform_later)
  end

  def september_export(state:, weight_in_payload: false, order_weight: 1.5)
    previous = ENV["POLAND_TRACKS_ENABLED"]
    ENV["POLAND_TRACKS_ENABLED"] = "false"
    order = create(:order, user: user, status: :paid, webpay_paid_at: paid_at,
                           delivery_type: "ikeya_delivery", track_number: nil, weight: order_weight,
                           address_json: { "delivery" => { "address" => {
                             "city" => "Минск", "street" => "Ленина", "house" => "1" } } })
    create(:order_item, order: order, name_snapshot: "Стеллаж", quantity: 1, price: 300,
                        poland_price_pln: 99.99, poland_product_url: "https://www.ikea.com/pl/pl/p/example-123/")
    snapshot = PolandTracks::Payload.snapshot(order)
    snapshot = snapshot.except("weight") unless weight_in_payload
    PolandTrackExport.create!(order: order, state: state, payload_json: JSON.generate(snapshot))
  ensure
    previous.nil? ? ENV.delete("POLAND_TRACKS_ENABLED") : ENV["POLAND_TRACKS_ENABLED"] = previous
  end

  it "previews pending exports missing weight without writing" do
    export = september_export(state: "pending")
    report = described_class.call(as_of: as_of, dry_run: true)
    expect(report[:counts]["ready_to_patch"]).to eq(1)
    expect(JSON.parse(export.reload.payload_json)).not_to have_key("weight")
  end

  it "patches pending snapshots and enqueues dispatch" do
    export = september_export(state: "pending")
    clear_enqueued_jobs
    report = described_class.call(as_of: as_of, dry_run: false)
    expect(report[:counts]["patched"]).to eq(1)
    payload = JSON.parse(export.reload.payload_json)
    expect(payload["weight"]).to eq("1500")
    expect(payload.keys.take(2)).to eq(%w[delivery_type weight])
    expect(enqueued_jobs.map { |job| job[:job] }).to include(PolandTrackExportJob)
  end

  it "reopens blocked exports when weight can be filled" do
    export = september_export(state: "blocked")
    export.update!(last_error: "old")
    report = described_class.call(as_of: as_of, dry_run: false)
    expect(report[:counts]["patched"]).to eq(1)
    expect(export.reload.state).to eq("pending")
    expect(export.last_error).to be_nil
    expect(JSON.parse(export.payload_json)["weight"]).to eq("1500")
  end

  it "does not rewrite succeeded remote creates" do
    export = september_export(state: "succeeded")
    report = described_class.call(as_of: as_of, dry_run: false)
    expect(report[:counts]["succeeded_remote_immutable"]).to eq(1)
    expect(JSON.parse(export.reload.payload_json)).not_to have_key("weight")
  end

  it "skips snapshots that already include weight" do
    export = september_export(state: "pending", weight_in_payload: true)
    report = described_class.call(as_of: as_of, dry_run: false)
    expect(report[:counts]["already_has_weight"]).to eq(1)
    expect(JSON.parse(export.reload.payload_json)["weight"]).to eq("1500")
  end
end
