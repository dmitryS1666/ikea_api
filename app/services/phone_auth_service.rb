class PhoneAuthService
  def self.send_code(phone:, metadata: {})
    ip_address = metadata.delete(:ip_address)
    user_agent = metadata.delete(:user_agent)

    request = PhoneVerificationRequest.create!(
      phone: phone,
      status: 'pending',
      ip_address: ip_address,
      user_agent: user_agent,
      metadata: metadata
    )

    if phone.blank?
      request.update!(status: 'error', error_message: 'Неверный формат телефона')
      return { error: 'Неверный формат телефона' }
    end

    # Удаляем старые коды
    VerificationCode.where(phone: phone).destroy_all

    code = VerificationCode.generate_code
    request.update!(code: code)

    VerificationCode.create!(
      phone: phone, 
      code: code, 
      expires_at: 10.minutes.from_now
    )

    begin
      SmsSenderService.send(phone, code)
      request.update!(status: 'success')
      { success: true, message: 'Код отправлен' }
    rescue => e
      request.update!(status: 'error', error_message: e.message)
      { error: "Ошибка отправки SMS: #{e.message}" }
    end
  end

  def self.verify_code(phone:, code:)
    verification = VerificationCode.valid_code(phone, code).first
    
    return { error: 'Неверный или просроченный код' } unless verification

    verification.destroy!

    user = User.find_or_initialize_by(phone: phone)
    
    is_new_user = user.new_record?
    
    if is_new_user
      # Генерируем рандомный пароль, так как валидация password выключена для phone auth,
      # но has_secure_password требует его наличия внутри себя для дайджеста.
      # Либо мы обошли валидацию, но password_digest нужен для модели? 
      # has_secure_password создает password= метод.
      
      # Используем номер телефона как username, если он уникален
      user.username = phone
      user.password = SecureRandom.hex(12)
      user.role = 'user'
      
      unless user.save
        return { error: user.errors.full_messages.join(', ') }
      end
    end

    { success: true, user: user, is_new: is_new_user }
  end
end
