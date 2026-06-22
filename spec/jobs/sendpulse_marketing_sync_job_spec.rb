# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendpulseMarketingSyncJob, type: :job do
  let(:user) { create(:user, email: "user@example.com") }

  it "subscribes user email in SendPulse" do
    sync = instance_double(Sendpulse::MailingListSync)
    allow(Sendpulse::MailingListSync).to receive(:subscribe).and_return(
      Sendpulse::Result.new(success: true, response: { "ok" => true })
    )

    described_class.perform_now(user.id, "subscribe")

    expect(Sendpulse::MailingListSync).to have_received(:subscribe).with(
      email: user.email,
      name: user.full_name
    )
  end
end
