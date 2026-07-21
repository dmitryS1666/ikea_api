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

  it "unsubscribes even when email is not verified" do
    user.update_columns(email_verified_at: nil)
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")

    result = described_class.unsubscribe_by_token!(token)

    expect(result).to include(success: true, status: "unsubscribed")
    expect(user.reload).to have_attributes(
      email_marketing: false,
      newsletter_consent: false
    )
    expect(user.email_suppressed?).to be(true)
  end

  it "blocks verify/marketing mail after unsubscribe of an unverified address, but keeps order emails" do
    user.update_columns(email_verified_at: nil, email_marketing: true, newsletter_consent: true)
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")

    described_class.unsubscribe_by_token!(token)
    user.reload

    expect(user.email_suppressed?).to be(true)
    expect(MarketingSubscriptionService.subscribed?(user)).to be(false)

    expect do
      TransactionalEmailService.send_welcome(user)
    end.not_to have_enqueued_job(SendpulseEmailJob)

    order = create(:order, user: user, checkout_draft: false)
    expect do
      TransactionalEmailService.send_order_email(:order_created, order)
    end.to change { enqueued_jobs.count }.by_at_least(1)
  end

  it "still allows transactional email after verified user unsubscribes" do
    user.update!(email_verified_at: 1.day.ago)
    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")

    described_class.unsubscribe_by_token!(token)
    user.reload

    expect(user.email_suppressed?).to be(false)
    expect(MarketingSubscriptionService.subscribed?(user)).to be(false)
  end

  it "keeps order emails after change to unverified email and unsubscribe" do
    user.update_columns(email_verified_at: nil, email_marketing: true, newsletter_consent: true)
    new_email = "fresh_#{SecureRandom.hex(4)}@example.com"

    user.update!(email: new_email)
    expect(user.reload.email_verified?).to be(false)
    expect(user.email_suppressed?).to be(false)

    token = Rack::Utils.parse_query(URI(described_class.url_for(user)).query).fetch("token")
    described_class.unsubscribe_by_token!(token)
    user.reload

    expect(user.email).to eq(new_email)
    expect(user.email_suppressed?).to be(true)

    expect do
      TransactionalEmailService.send_welcome(user)
    end.not_to have_enqueued_job(SendpulseEmailJob)

    order = create(:order, user: user, checkout_draft: false)
    expect do
      TransactionalEmailService.send_order_email(:order_created, order)
    end.to change { enqueued_jobs.count }.by_at_least(1)
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
