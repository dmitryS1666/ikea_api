# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketingUnsubscribeService do
  include ActiveJob::TestHelper

  let!(:user) do
    create(:user, email: "customer@example.com", email_marketing: true, newsletter_consent: true)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(MarketingSubscriptionService).to receive(:sync_user!)
  end

  it "unsubscribes a user through a signed link and records consent history" do
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")

    result = described_class.unsubscribe_by_token!(token)

    expect(result).to include(success: true, status: "unsubscribed")
    expect(user.reload).to have_attributes(email_marketing: false, newsletter_consent: false)
    expect(user.consent_records.for_type(:newsletter_email).last).to have_attributes(
      accepted: false,
      source: "email_unsubscribe_link"
    )
  end

  it "is idempotent for an already unsubscribed user" do
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")

    described_class.unsubscribe_by_token!(token)
    expect do
      result = described_class.unsubscribe_by_token!(token)
      expect(result).to include(success: true, status: "already_unsubscribed")
    end.not_to change { user.consent_records.count }
  end

  it "rejects a modified token" do
    expect do
      described_class.unsubscribe_by_token!("invalid-token")
    end.to raise_error(described_class::InvalidToken)
  end

  it "invalidates a token after the user email changes" do
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")
    user.update_column(:email, "new@example.com")

    expect do
      described_class.unsubscribe_by_token!(token)
    end.to raise_error(described_class::InvalidToken)
  end
end
