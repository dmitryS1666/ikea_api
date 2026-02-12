class EmailVerificationService
  def self.send_code(user, new_email)
    # Заглушка вызова сервиса рассылки
    Rails.logger.info "Sending verification email to #{new_email} for user #{user.id}"
    # В реальной системе здесь был бы вызов API (SendPulse, Mailchimp и т.д.)
    true
  end
end
