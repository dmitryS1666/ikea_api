# frozen_string_literal: true

class EmailVerificationService
  RESEND_INTERVAL = 60.seconds

  class << self
    def send_code(user, new_email)
      TransactionalEmailService.send_email_changed(user, new_email)
      true
    end

    def issue_token!(user:, email:, purpose:, invalidate_all_pending: false)
      pending_tokens = EmailVerificationToken.where(user: user, verified_at: nil)
      pending_tokens = pending_tokens.where(purpose: purpose) unless invalidate_all_pending
      pending_tokens.delete_all

      EmailVerificationToken.create!(
        user: user,
        email: normalize_email(email),
        token: SecureRandom.urlsafe_base64(32),
        purpose: purpose,
        expires_at: EmailVerificationToken::TTL.from_now
      )
    end

    # Повторно отправляет подтверждение текущего email пользователя.
    # Проверка и выпуск токена выполняются под блокировкой пользователя, чтобы
    # параллельные запросы не обходили ограничение частоты.
    def resend_current_email!(user)
      token_record = nil

      user.with_lock do
        user.reload
        email = normalize_email(user.email)

        return failure(
          "Email отсутствует",
          status: :unprocessable_entity,
          code: "email_missing"
        ) if email.blank?

        return failure(
          "Email уже подтверждён",
          status: :conflict,
          code: "email_already_verified"
        ) if user.email_verified?

        last_sent_at = EmailVerificationToken.where(user_id: user.id).maximum(:created_at)
        if last_sent_at.present? && last_sent_at > RESEND_INTERVAL.ago
          retry_after = [(RESEND_INTERVAL - (Time.current - last_sent_at)).ceil, 1].max
          return failure(
            "Письмо уже отправлено. Повторите через #{retry_after} сек.",
            status: :too_many_requests,
            code: "email_verification_rate_limited",
            retry_after: retry_after
          )
        end

        token_record = issue_token!(
          user: user,
          email: email,
          purpose: "welcome",
          invalidate_all_pending: true
        )
      end

      TransactionalEmailService.send_email_verification(user, token_record)
      { success: true, token: token_record }
    rescue StandardError
      # Если письмо даже не удалось поставить в очередь, новый токен не должен
      # блокировать следующую попытку на 60 секунд.
      token_record&.delete if token_record&.persisted? && !token_record.verified?
      raise
    end

    def verify_url(token_record)
      base = Seo::PublicSiteUrl.resolve
      "#{base}/api/v1/account/profile/change_email_verify?token=#{CGI.escape(token_record.token)}"
    end

    def verify!(token:, email: nil)
      initial_record = EmailVerificationToken.active.find_by(token: token.to_s)
      return { error: "Неверный или просроченный токен" } unless initial_record

      user = initial_record.user
      result = nil

      user.with_lock do
        record = EmailVerificationToken.active.lock.find_by(id: initial_record.id, token: token.to_s)
        return { error: "Неверный или просроченный токен" } unless record
        return { error: "Email не совпадает" } if email.present? && record.email != normalize_email(email)

        unless user.update(email: record.email, email_verified_at: Time.current)
          return { error: user.errors.full_messages.join(", ") }
        end

        record.verify!
        EmailVerificationToken
          .where(user_id: user.id, verified_at: nil)
          .where.not(id: record.id)
          .delete_all

        result = { success: true, user: user }
      end

      result
    end

    private

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    def failure(message, status:, code:, retry_after: nil)
      {
        success: false,
        error: message,
        status: status,
        code: code,
        retry_after: retry_after
      }.compact
    end
  end
end
