# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sendpulse::UnsubscribeHandler do
  include ActiveJob::TestHelper

  let!(:user) { create(:user, email: "user@example.com", email_marketing: true, newsletter_consent: true) }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(MarketingSubscriptionService).to receive(:sync_user!)
  end

  it "marks user unsubscribed and stores consent history" do
    result = described_class.call("event" => "unsubscribe", "email" => "user@example.com")

    expect(result[:success]).to be(true)
    user.reload
    expect(user.email_marketing).to be(false)
    expect(user.newsletter_consent).to be(false)
    expect(user.consent_records.for_type(:newsletter_email).last).to have_attributes(
      accepted: false,
      source: "unsubscribe_webhook"
    )
  end
end
