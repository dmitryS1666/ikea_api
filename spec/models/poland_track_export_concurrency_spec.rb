require "rails_helper"
require "timeout"

# This spec deliberately commits fixtures so two PostgreSQL connections can see
# the same row. It deletes only the records it creates, never truncates the DB.
RSpec.describe PolandTrackExport, type: :model do
  self.use_transactional_tests = false

  it "allows only one POST across two real concurrent database connections" do
    old_enabled = ENV["POLAND_TRACKS_ENABLED"]
    old_key = ENV["POLAND_TRACKS_API_KEY"]
    ENV["POLAND_TRACKS_ENABLED"] = "false"
    ENV["POLAND_TRACKS_API_KEY"] = "test-key"
    allow(TelegramService).to receive(:send_message).and_return(nil)
    allow(CrmSyncJob).to receive(:perform_later)
    allow(UpdateOrderTrackingInfoJob).to receive(:perform_later)

    user = create(:user)
    order = create(:order, user: user, status: :paid, delivery_type: "ikeya_delivery")
    payload = {
      "delivery_type" => 5, "nomerikea" => order.public_uid, "delivery_address" => "Минск, Ленина, д. 1",
      "recipient" => {
        "first_name" => "Иван", "last_name" => "Иванов", "email" => "example@example.com",
        "phone" => "+375291112233", "phone_country" => "by", "birthdate" => "01.01.1990",
        "document_country" => "by", "address_country" => "by", "passport_serial" => "AB",
        "passport_number" => "1234567", "iin" => "1234567A123AB1", "passport_date" => "01.01.2015",
        "passport_founder" => "РОВД", "region" => "Минская", "city" => "Минск", "street" => "Ленина",
        "building" => "1", "index" => "220000"
      },
      "items" => [{ "name" => "Стеллаж", "count" => 1, "price" => 99.99, "link" => "https://www.ikea.com/pl/pl/p/example-123/" }]
    }
    export = described_class.create!(order: order, payload_json: payload.to_json)
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    entered = Queue.new
    release = Queue.new
    connection_ids = Queue.new
    allow(PolandTracks::Client).to receive(:create!) do
      entered << true
      Timeout.timeout(10) { release.pop }
      { "id" => 1001, "code" => "TEST", "shop_number" => "TESTPL", "recipient_id" => 55, "nomerikea" => order.public_uid }
    end

    perform = lambda do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection_ids << connection.select_value("SELECT pg_backend_pid()")
        PolandTracks::ExportService.call(described_class.find(export.id))
      end
    end
    first = Thread.new(&perform)
    Timeout.timeout(5) { entered.pop }
    second = Thread.new(&perform)
    raise "Second worker did not finish" unless second.join(5)
    second.value
    release << true
    raise "First worker did not finish" unless first.join(5)
    first.value

    expect([connection_ids.pop, connection_ids.pop].uniq.size).to eq(2)
    expect(PolandTracks::Client).to have_received(:create!).once
    expect(export.reload).to have_attributes(state: "succeeded", attempts: 1)
  ensure
    release << true if release
    [first, second].compact.each do |thread|
      thread.kill unless thread.join(2)
      thread.join
    end
    # Model callbacks can create audit/status/finance rows; dependent associations
    # remove them through the normal cleanup paths.
    order&.destroy!
    user&.destroy!
    old_enabled.nil? ? ENV.delete("POLAND_TRACKS_ENABLED") : ENV["POLAND_TRACKS_ENABLED"] = old_enabled
    old_key.nil? ? ENV.delete("POLAND_TRACKS_API_KEY") : ENV["POLAND_TRACKS_API_KEY"] = old_key
  end
end
