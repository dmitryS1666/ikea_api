# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketingSubscriptionService do
  describe ".subscribed?" do
    it "requires email, verification and marketing opt-in" do
      user = build(
        :user,
        email: "customer@example.com",
        email_verified_at: Time.current,
        email_marketing: true,
        newsletter_consent: false
      )

      expect(described_class.subscribed?(user)).to be(true)
    end

    it "is false without verification even when opted in" do
      user = build(
        :user,
        email: "customer@example.com",
        email_verified_at: nil,
        email_marketing: true,
        newsletter_consent: true
      )

      expect(described_class.subscribed?(user)).to be(false)
      expect(described_class.opted_in?(user)).to be(true)
    end

    it "is false without marketing consent even when verified" do
      user = build(
        :user,
        email: "customer@example.com",
        email_verified_at: Time.current,
        email_marketing: false,
        newsletter_consent: false
      )

      expect(described_class.subscribed?(user)).to be(false)
    end
  end
end
