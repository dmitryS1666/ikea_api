# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailVerificationService do
  let(:user) { create(:user, email_verified_at: nil) }

  describe ".resend_current_email!" do
    it "removes the newly issued token when email enqueueing fails" do
      allow(TransactionalEmailService)
        .to receive(:send_email_verification)
        .and_raise(StandardError, "queue unavailable")

      expect do
        described_class.resend_current_email!(user)
      end.to raise_error(StandardError, "queue unavailable")

      expect(EmailVerificationToken.where(user: user, verified_at: nil)).to be_empty
    end
  end

  describe ".verify_url" do
    it "keeps the public verification link format" do
      token = described_class.issue_token!(
        user: user,
        email: user.email,
        purpose: "welcome"
      )

      expect(described_class.verify_url(token)).to eq(
        "https://ikeya.by/api/v1/account/profile/change_email_verify?token=#{CGI.escape(token.token)}"
      )
    end
  end
end
