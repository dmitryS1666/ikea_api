require "rails_helper"

RSpec.describe NbrbApiService do
  describe ".get_rate" do
    let(:date) { Date.new(2026, 7, 28) }
    let(:url) { "https://www.nbrb.by/api/exrates/rates/451?ondate=2026-07-28" }

    it "returns parsed rate on success" do
      stub_request(:get, url)
        .to_return(
          status: 200,
          body: {
            Date: "2026-07-28T00:00:00",
            Cur_OfficialRate: 3.2849,
            Cur_Scale: 1
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = described_class.get_rate("EUR", date)

      expect(result).to eq(
        currency_code: "EUR",
        date: date,
        rate: 3.2849,
        scale: 1
      )
    end

    it "uses short open/read timeouts" do
      expect(described_class::OPEN_TIMEOUT).to be <= 3
      expect(described_class::READ_TIMEOUT).to be <= 5

      expect(HTTParty).to receive(:get).with(
        url,
        hash_including(
          open_timeout: described_class::OPEN_TIMEOUT,
          read_timeout: described_class::READ_TIMEOUT,
          timeout: described_class::READ_TIMEOUT
        )
      ).and_return(
        instance_double(
          HTTParty::Response,
          success?: true,
          body: {
            Date: "2026-07-28T00:00:00",
            Cur_OfficialRate: 3.28,
            Cur_Scale: 1
          }.to_json
        )
      )

      described_class.get_rate("EUR", date)
    end

    it "returns nil on timeout instead of raising" do
      stub_request(:get, url).to_timeout

      expect(described_class.get_rate("EUR", date)).to be_nil
    end

    it "returns nil for unknown currency" do
      expect(described_class.get_rate("BTC", date)).to be_nil
    end
  end
end
