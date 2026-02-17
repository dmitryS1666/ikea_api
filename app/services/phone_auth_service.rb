class PhoneAuthService
  def self.send_code(phone:, metadata: {})
    ip_address = metadata.delete(:ip_address)
    user_agent = metadata.delete(:user_agent)

    # Нормализация номера телефона (оставляем только цифры)
    phone = phone.to_s.gsub(/\D/, '')

    request = PhoneVerificationRequest.create!(
      phone: phone,
      status: 'pending',
      ip_address: ip_address,
      user_agent: user_agent,
      metadata: metadata
    )

    if phone.blank? || phone.length < 10
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
      # В будущем здесь будет вызов API для звонка
      # Код - это последние 4 цифры входящего номера
      Rails.logger.info "\n[CALL MOCK] Initiating call to #{phone}. Verification code: #{code}\n"
      puts "\n[CALL MOCK] Initiating call to #{phone}. Verification code: #{code}\n"
      
      request.update!(status: 'success')
      { success: true, message: 'Ожидайте звонок. Введите последние 4 цифры номера.' }
    rescue => e
      request.update!(status: 'error', error_message: e.message)
      { error: "Ошибка при инициации звонка: #{e.message}" }
    end
  end

  def self.verify_code(phone:, code:, username: nil, email: nil)
    # Нормализация номера телефона
    phone = phone.to_s.gsub(/\D/, '')
    
    verification = VerificationCode.valid_code(phone, code).first
    
    return { error: 'Неверный или просроченный код' } unless verification

    verification.destroy!

    user = User.find_or_initialize_by(phone: phone)
    
    is_new_user = user.new_record?
    
    if is_new_user
      # При регистрации обязательно имя (username)
      if username.blank?
        return { error: 'Имя обязательно для регистрации' }
      end

      user.username = username
      user.email = email if email.present?
      user.password = SecureRandom.hex(12)
      user.role = 'user'
      
      unless user.save
        return { error: user.errors.full_messages.join(', ') }
      end
    else
      # Если пользователь уже существует, обновляем email, если он передан
      user.email = email if email.present?
      user.save if user.changed?
    end

    { success: true, user: user, is_new: is_new_user }
  end
end
