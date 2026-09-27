require "rails_helper"

RSpec.describe PolandTracks::SeptemberBackfill do
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
    ENV["POLAND_TRACKS_ENABLED"] = "false"
    ENV["POLAND_TRACKS_API_KEY"] = "test-key"
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before do
    allow(TelegramService).to receive(:send_message)
    allow(CrmSyncJob).to receive(:perform_later)
    allow(UpdateOrderTrackingInfoJob).to receive(:perform_later)
  end

  def historical_order(**attributes)
    order = create(:order, { user: user, status: :paid, webpay_paid_at: paid_at,
                             delivery_type: "ikeya_delivery", track_number: nil,
                             address_json: { "delivery" => { "address" => { "city" => "Минск", "street" => "Ленина", "house" => "1" } } } }.merge(attributes))
    create(:order_item, order: order, name_snapshot: "Стеллаж", quantity: 1, price: 300,
                        poland_price_pln: 99.99, poland_product_url: "https://www.ikea.com/pl/pl/p/example-123/")
    order
  end

  def run_backfill(**options)
    described_class.call(as_of: as_of, **options)
  end

  it "previews without writing exports, editing orders/items or enqueuing any job" do
    order = historical_order
    before_order = order.reload.attributes
    before_items = order.order_items.map(&:attributes)
    clear_enqueued_jobs
    report = nil
    expect { report = run_backfill }.not_to change(PolandTrackExport, :count)
    expect(enqueued_jobs).to be_empty
    expect(report[:counts]).to include("ready" => 1)
    expect(order.reload.attributes).to eq(before_order)
    expect(order.order_items.reload.map(&:attributes)).to eq(before_items)
  end

  it "uses the exact 21-day lower boundary and exclusive as_of upper boundary" do
    start = Time.iso8601(as_of) - 21.days
    included = historical_order(webpay_paid_at: start)
    historical_order(webpay_paid_at: start - 1.second)
    historical_order(webpay_paid_at: Time.iso8601(as_of))
    expect(run_backfill[:details].map { |row| row[:order_id] }).to eq([included.id])
  end

  it "clamps the lower boundary to September 1 in Europe/Minsk" do
    included = historical_order(webpay_paid_at: Time.iso8601("2026-09-01T00:00:00+03:00"))
    historical_order(webpay_paid_at: Time.iso8601("2026-08-31T23:59:59+03:00"))
    report = described_class.call(as_of: "2026-09-10T12:00:00+03:00")
    expect(report[:from]).to eq("2026-09-01T00:00:00+03:00")
    expect(report[:details].map { |row| row[:order_id] }).to eq([included.id])
  end

  it "never includes October or a different year" do
    included = historical_order(webpay_paid_at: Time.iso8601("2026-09-30T23:59:59+03:00"))
    historical_order(webpay_paid_at: Time.iso8601("2026-10-01T00:00:00+03:00"))
    report = described_class.call(as_of: "2026-10-02T12:00:00+03:00")
    expect(report[:to_exclusive]).to eq("2026-10-01T00:00:00+03:00")
    expect(report[:details].map { |row| row[:order_id] }).to eq([included.id])
    expect(described_class.call(as_of: "2027-09-27T12:00:00+03:00")[:examined]).to eq(0)
  end

  it "includes later fulfilment states and selects by payment time, not creation time" do
    order = historical_order(status: :shipped, created_at: Time.iso8601("2026-08-01T12:00:00+03:00"))
    expect(run_backfill[:details].map { |row| row[:order_id] }).to include(order.id)
  end

  it "uses the first paid status event when Webpay timestamp is absent" do
    order = historical_order(status: :shipped, webpay_paid_at: nil)
    order.order_status_events.create!(to_status: "paid", changed_at: paid_at, source: "admin")
    order.order_status_events.create!(to_status: "paid", changed_at: Time.iso8601("2026-10-01T12:00:00+03:00"), source: "admin")
    expect(run_backfill[:details].map { |row| row[:order_id] }).to eq([order.id])
  end

  it "does not use a later repeated paid event to include an older payment" do
    order = historical_order(status: :shipped, webpay_paid_at: nil)
    order.order_status_events.create!(to_status: "paid", changed_at: Time.iso8601("2026-08-01T12:00:00+03:00"), source: "admin")
    order.order_status_events.create!(to_status: "paid", changed_at: paid_at, source: "admin")
    expect(run_backfill[:examined]).to eq(0)
  end

  it "gives Webpay precedence over a conflicting paid event" do
    order = historical_order(status: :shipped, webpay_paid_at: Time.iso8601("2026-08-01T12:00:00+03:00"))
    order.order_status_events.create!(to_status: "paid", changed_at: paid_at, source: "admin")
    expect(run_backfill[:examined]).to eq(0)
  end

  it "excludes cancelled, unpaid, draft, refunded and undated orders" do
    historical_order(status: :cancelled)
    historical_order(status: :created)
    historical_order(checkout_draft: true)
    refunded = historical_order
    refunded.finance_entry.update!(payment_status: "refunded")
    historical_order(status: :shipped, webpay_paid_at: nil)
    expect(run_backfill[:examined]).to eq(0)
  end

  it "classifies missing PLN snapshots as blocked without substituting BYN" do
    order = historical_order
    order.order_items.first.update_columns(poland_price_pln: nil)
    row = run_backfill[:details].first
    expect(row).to include(result: "blocked")
    expect(row[:error]).to include("PLN snapshot")
    expect(order.order_items.first.reload.poland_price_pln).to be_nil
  end

  it "validates recipient and prices even while a Europost track is missing" do
    order = historical_order(delivery_type: "europost_pickup", address_json: { "pickup_point_id" => 12345 })
    expect(run_backfill[:counts]).to include("waiting_track" => 1)
    order.order_items.first.update_columns(poland_price_pln: nil)
    expect(run_backfill[:counts]).to include("blocked" => 1)
  end

  it "enqueues ready orders once and preserves every existing export state" do
    order = historical_order
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    clear_enqueued_jobs
    expect { run_backfill(dry_run: false) }.to change(PolandTrackExport, :count).by(1)
    export = PolandTrackExport.find_by!(order: order)
    expect(export.state).to eq("pending")
    expect(enqueued_jobs.count { |job| job[:job] == PolandTrackExportJob }).to eq(1)
    PolandTrackExport::STATES.each do |state|
      export.update!(state: state)
      before = export.reload.attributes
      clear_enqueued_jobs
      report = run_backfill(dry_run: false)
      expect(report[:counts]).to include("existing" => 1)
      expect(export.reload.attributes).to eq(before)
      expect(enqueued_jobs).to be_empty
    end
  end

  it "stores a blocked record for manual correction without queuing it" do
    order = historical_order
    order.order_items.first.update_columns(poland_price_pln: nil)
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    clear_enqueued_jobs
    run_backfill(dry_run: false)
    expect(PolandTrackExport.find_by!(order: order).state).to eq("blocked")
    expect(enqueued_jobs).to be_empty
  end

  it "caps the batch when limit is supplied and works with the integration disabled in preview" do
    2.times { historical_order }
    expect(run_backfill(limit: 1)[:examined]).to eq(1)
    expect { run_backfill(dry_run: false) }.to raise_error(ArgumentError, /Enable/)
  end

  it "never calls shipment creation or the Poland API itself" do
    historical_order
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    expect(PolandTracks::Client).not_to receive(:create!)
    expect(EuropostCreateShipmentJob).not_to receive(:perform_later)
    report = BackfillPolandTrackExportsJob.perform_now(as_of: as_of, dry_run: false)
    expect(report[:examined]).to eq(1)
  end

  it "rejects ambiguous times and non-boolean dry_run values" do
    expect { described_class.call(as_of: "2026-09-27") }.to raise_error(ArgumentError)
    expect { run_backfill(dry_run: "false") }.to raise_error(ArgumentError)
  end
end
