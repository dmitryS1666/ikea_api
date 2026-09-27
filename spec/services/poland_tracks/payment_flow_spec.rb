require "rails_helper"
require "digest/md5"

RSpec.describe "Poland export after verified Webpay payment" do
  around do |example|
    previous = ENV["POLAND_TRACKS_ENABLED"]
    ENV["POLAND_TRACKS_ENABLED"] = "true"
    example.run
  ensure
    previous.nil? ? ENV.delete("POLAND_TRACKS_ENABLED") : ENV["POLAND_TRACKS_ENABLED"] = previous
  end

  let(:order) { create(:order, status: :created, payment_order_number: "PAY-TEST-POLAND", total_amount: 100) }
  let(:params) { signed_params }

  def signed_params(overrides = {})
    data = { "site_order_id" => order.payment_order_number, "payment_type" => "1",
             "amount" => "100.00", "currency_id" => "BYN", "transaction_id" => "verified-poland-tx" }.merge(overrides)
    fields = %w[batch_timestamp currency_id amount payment_method order_id site_order_id transaction_id payment_type rrn]
    data["wsb_signature"] = Digest::MD5.hexdigest(fields.map { |key| data[key].to_s }.join + "test")
    data
  end

  before do
    # Keep order callbacks active; isolate unrelated outbound notifications.
    allow(TelegramService).to receive(:send_message).and_return(nil)
    allow(WebpayConfig).to receive(:current).and_return(double(secret_key: "test", notify_trusted_ips: [], currency_id: "BYN"))
    allow(WebpayGetTransactionService).to receive(:billing_configured?).and_return(false)
    allow(EuropostCreateShipmentJob).to receive(:perform_later)
    allow(CrmSyncJob).to receive(:perform_later)
  end

  it "creates one outbox record and one Europost job across repeated verified notifications" do
    expect(WebpayPaymentCompletionService.complete_from_notification(params)).to eq(:paid)
    expect(WebpayPaymentCompletionService.complete_from_notification(params)).to eq(:already_paid)
    expect(PolandTrackExport.where(order_id: order.id).count).to eq(1)
    expect(EuropostCreateShipmentJob).to have_received(:perform_later).with(order.id).once
  end

  it "does not export an invalid notification" do
    expect(WebpayPaymentCompletionService.complete_from_notification(params.merge("wsb_signature" => "invalid"))).to eq(:invalid_signature)
    expect(PolandTrackExport.where(order_id: order.id)).not_to exist
  end

  it "does not export an amount mismatch" do
    expect(WebpayPaymentCompletionService.complete_from_notification(signed_params("amount" => "1.00"))).to eq(:amount_mismatch)
    expect(PolandTrackExport.where(order_id: order.id)).not_to exist
  end

  { "courier" => 4, "ikeya_delivery" => 5 }.each do |delivery_type, api_type|
    it "captures #{delivery_type} after verified payment with API type #{api_type}" do
      order.update!(delivery_type: delivery_type, track_number: nil)
      expect(WebpayPaymentCompletionService.complete_from_notification(params)).to eq(:paid)
      export = PolandTrackExport.find_by!(order_id: order.id)
      expect(JSON.parse(export.payload_json)["delivery_type"]).to eq(api_type)
      if api_type == 5
        expect(EuropostCreateShipmentJob).not_to have_received(:perform_later)
      else
        expect(EuropostCreateShipmentJob).to have_received(:perform_later).with(order.id).once
      end
    end
  end
end
