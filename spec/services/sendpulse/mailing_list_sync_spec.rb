# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sendpulse::MailingListSync do
  let(:client) { instance_double(Sendpulse::Client) }

  before do
    allow(Sendpulse::Client).to receive(:new).and_return(client)
    allow(ENV).to receive(:[]).with("SENDPULSE_MAILING_LIST_ID").and_return("12345")
  end

  describe ".subscribe" do
    it "adds email to configured mailing list" do
      allow(client).to receive(:post).and_return({ "result" => true })

      result = described_class.subscribe(email: "user@example.com", name: "User")

      expect(result.success?).to be(true)
      expect(client).to have_received(:post).with(
        "/addressbooks/12345/emails",
        hash_including(emails: [hash_including(email: "user@example.com")])
      )
    end
  end

  describe ".unsubscribe" do
    it "removes email from configured mailing list" do
      allow(client).to receive(:delete).and_return({ "result" => true })

      result = described_class.unsubscribe(email: "user@example.com")

      expect(result.success?).to be(true)
      expect(client).to have_received(:delete).with(
        "/addressbooks/12345/emails",
        { emails: ["user@example.com"] }
      )
    end
  end
end
