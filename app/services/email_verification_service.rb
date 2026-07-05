class EmailVerificationService
  class << self
    def send_code(user, new_email)
      TransactionalEmailService.send_email_changed(user, new_email)
      true
    end

    def issue_token!(user:, email:, purpose:)
      EmailVerificationToken.where(user: user, purpose: purpose, verified_at: nil).delete_all

      EmailVerificationToken.create!(
        user: user,
        email: email.to_s.strip.downcase,
        token: SecureRandom.urlsafe_base64(32),
        purpose: purpose,
        expires_at: EmailVerificationToken::TTL.from_now
      )
    end

    def verify_url(token_record)
      base = Seo::PublicSiteUrl.resolve
      "#{base}/account/verify-email?token=#{CGI.escape(token_record.token)}"
    end

    def verify!(token:, email: nil)
      record = EmailVerificationToken.active.find_by(token: token.to_s)
      return { error: "Неверный или просроченный токен" } unless record
      return { error: "Email не совпадает" } if email.present? && record.email != email.to_s.strip.downcase

      user = record.user
      user.email = record.email
      unless user.save
        return { error: user.errors.full_messages.join(", ") }
      end

      record.verify!
      { success: true, user: user }
    end
  end
end
