module Api
  module V1
    class A1VerificationsController < ApplicationController
      # Используем метод из ApplicationController
      before_action :authenticate_user_optional

      # POST /api/v1/a1/request
      # Body: { phone: "+375...", context: "passport_update" }
      def request_call
        phone = params.require(:phone)
        context = params[:context].presence || 'passport_update'

        result = PhoneAuthService.send_code(
          phone: phone, 
          metadata: { 
            user_id: current_user&.id, 
            context: context,
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          }
        )

        if result[:success]
          # Находим созданный код для возврата ID (хотя ID теперь не так важен)
          verification = VerificationCode.find_by(phone: phone.gsub(/\D/, ''))
          render json: {
            verification_id: verification&.id,
            phone: phone,
            display_message: "Введите последние 4 цифры номера, с которого поступил звонок",
            caller_number_masked: "+375 (**) ***-**-#{verification&.code}",
            expires_at: verification&.expires_at&.iso8601
          }, status: :created
        else
          render json: { error: result[:error] }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/a1/verify
      # Body: { verification_id: 123, last4: "1234" }
      def verify_call
        # Для совместимости принимаем verification_id, но искать будем по телефону и коду
        # Если verification_id передан, попробуем найти телефон
        last4 = params.require(:last4)
        
        verification = nil
        if params[:verification_id].present?
          verification = VerificationCode.find_by(id: params[:verification_id], code: last4)
        end
        
        # Если не нашли по ID, попробуем по телефону (если передан)
        if verification.nil? && params[:phone].present?
          verification = VerificationCode.valid_code(params[:phone].gsub(/\D/, ''), last4).first
        end

        if verification && verification.expires_at > Time.current
          render json: { success: true, verification_id: verification.id, expires_at: verification.expires_at.iso8601 }
        else
          render json: { success: false, error: 'invalid_code_or_expired' }, status: :unprocessable_entity
        end
      end
    end
  end
end
