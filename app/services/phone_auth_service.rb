class PhoneAuthService
  def self.send_code(phone:, metadata: {})
    ip_address = metadata.delete(:ip_address)
    user_agent = metadata.delete(:user_agent)
    context = metadata.delete(:context) || 'auth' # Default context is auth (login/reg)
    user_id = metadata.delete(:user_id)

    # Нормализация номера телефона (оставляем только цифры)
    phone = phone.to_s.gsub(/\D/, '')

    request = PhoneVerificationRequest.create!(
      phone: phone,
      status: 'pending',
      ip_address: ip_address,
      user_agent: user_agent,
      context: context,
      user_id: user_id,
      metadata: metadata
    )

    if phone.blank? || phone.length < 10
      request.update!(status: 'error', error_message: 'Неверный формат телефона')
      return { error: 'Неверный формат телефона' }
    end

    # Удаляем старые коды
    VerificationCode.where(phone: phone).destroy_all

    if PhoneAuthSetting.asterisk_enabled?
      caller_info = AsteriskCallAuthService.get_caller_info
      code = caller_info[:code]
      from_number = caller_info[:number]
    else
      code = PhoneAuthSetting::STATIC_TEST_CODE
      from_number = nil
    end

    request.update!(code: code)

    VerificationCode.create!(
      phone: phone, 
      code: code, 
      expires_at: 10.minutes.from_now
    )

    begin
      unless PhoneAuthSetting.asterisk_enabled?
        Rails.logger.warn "\n[ASTERISK DISABLED] Skipped call for #{phone}. Static verification code: #{code}\n"
        request.update!(status: 'success')
        return { success: true, message: 'Код подтверждения отправлен.' }
      end

      # Интеграция с asterisk.by
      result = AsteriskCallAuthService.initiate_call(to_phone: phone, from_number: from_number)

      if result[:success]
        Rails.logger.info "\n[ASTERISK CALL] Initiated call to #{phone}. Verification code: #{code}\n"
        request.update!(status: 'success')
        { success: true, message: 'Ожидайте звонок. Введите последние 4 цифры номера.' }
      else
        Rails.logger.error "\n[ASTERISK ERROR] Failed to initiate call to #{phone}. Error: #{result[:error]}\n"
        request.update!(status: 'error', error_message: result[:error])
        { error: "Ошибка при инициации звонка: #{result[:error]}" }
      end
    rescue => e
      Rails.logger.error "\n[ASTERISK EXCEPTION] #{e.message}\n"
      request.update!(status: 'error', error_message: e.message)
      { error: "Ошибка при инициации звонка: #{e.message}" }
    end
  end

  def self.verify_code(phone:, code:, username: nil, email: nil, personal_data_consent: nil)
    # Нормализация номера телефона
    phone = phone.to_s.gsub(/\D/, '')
    
    verification = VerificationCode.valid_code(phone, code).first
    
    return { error: 'Неверный или просроченный код' } unless verification

    user = User.find_or_initialize_by(phone: phone)
    is_new_user = user.new_record?

    if is_new_user
      if username.blank?
        return { error: 'Имя обязательно для регистрации' }
      end

      unless ConsentService.truthy?(personal_data_consent)
        return { error: 'Требуется согласие на обработку персональных данных', code: 'personal_data_consent_required' }
      end
    end

    verification.destroy!
    
    if is_new_user
      user.username = username
      user.email = email if email.present?
      user.password = SecureRandom.hex(12)
      user.role = 'user'
      
      unless user.save
        return { error: user.errors.full_messages.join(', ') }
      end

      ConsentService.record_registration_personal_data!(user: user)
      TransactionalEmailService.send_welcome(user) if user.email.present?
    else
      # Если пользователь уже существует, обновляем email, если он передан
      user.email = email if email.present?
      user.save if user.changed?
    end

    { success: true, user: user, is_new: is_new_user }
  end
end
