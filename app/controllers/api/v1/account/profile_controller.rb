module Api
  module V1
    module Account
      class ProfileController < ApplicationController
        before_action :authenticate_user

        # GET /api/v1/account/profile
        def show
          render json: user_payload(current_user)
        end

        # PATCH /api/v1/account/profile
        def update
          if params[:email].present? && params[:email] != current_user.email
            # Вызов сервиса рассылки для верификации (заглушка)
            EmailVerificationService.send_code(current_user, params[:email])
          end

          passport_error = save_passport_if_verified
          return passport_error if passport_error

          if current_user.update(profile_params)
            # Передача данных в CRM теперь через callback в модели User
            render json: user_payload(current_user)
          else
            render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/account/profile/change_phone_request
        def change_phone_request
          phone = params[:phone].to_s.gsub(/\D/, '')
          if phone.blank? || phone.length < 10
            return render json: { error: 'Неверный формат телефона' }, status: :unprocessable_entity
          end

          if User.exists?(phone: phone)
            return render json: { error: 'Этот номер телефона уже занят' }, status: :unprocessable_entity
          end

          result = PhoneAuthService.send_code(phone: phone, metadata: { user_id: current_user.id, context: 'change_phone' })
          if result[:success]
            render json: { message: result[:message] }
          else
            render json: { error: result[:error] }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/account/profile/change_phone_verify
        def change_phone_verify
          phone = params[:phone].to_s.gsub(/\D/, '')
          code = params[:code]

          verification = VerificationCode.valid_code(phone, code).first
          if verification
            verification.destroy!
            if current_user.update(phone: phone)
              render json: user_payload(current_user)
            else
              render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
            end
          else
            render json: { error: 'Неверный или просроченный код' }, status: :unauthorized
          end
        end

        # POST /api/v1/account/profile/change_email_verify
        def change_email_verify
          # Заглушка: в реальности здесь была бы проверка кода из письма
          code = params[:code]
          new_email = params[:email]

          if code == '1234' # Заглушка кода
            if current_user.update(email: new_email)
              render json: user_payload(current_user)
            else
              render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
            end
          else
            render json: { error: 'Неверный код подтверждения' }, status: :unauthorized
          end
        end

        private

        def profile_params
          params.permit(
            :username, :email, :phone, :country_code,
            :gdpr_consent, :newsletter_consent,
            :dob, :gender, :address,
            :telegram_marketing, :email_marketing,
            :first_name, :last_name, :middle_name,
            :region, :city, :postcode, :street, :house, :building, :apartment
          )
        end

        def save_passport_if_verified
          passport_input = extract_passport_input
          return nil if passport_input.blank?

          current_passport = current_user.passport_data
          passport_unchanged = UserPassportService.same?(passport_input, current_passport)
          return nil if passport_unchanged && current_user.passport_verified?

          verification_id = params[:verification_id].presence || params[:a1_verification_id].presence
          code = params[:code].presence || params[:last4].presence

          if verification_id.blank? || code.blank?
            return render json: {
              error: 'Для сохранения паспорта требуется подтверждение по звонку',
              code: 'passport_verification_required'
            }, status: :unprocessable_entity
          end

          begin
            UserPassportService.validate_passport_number!(passport_input)
          rescue ArgumentError => e
            return render json: { error: e.message }, status: :unprocessable_entity
          end

          expected_phone = current_user.phone.to_s.gsub(/\D/, '')
          verification = VerificationCode.find_by(id: verification_id, phone: expected_phone, code: code)
          unless verification&.expires_at&.> Time.current
            return render json: {
              error: 'Неверный или просроченный код',
              code: 'invalid_verification_code'
            }, status: :unauthorized
          end

          verified_phone = verification.phone
          verification.destroy!

          UserPassportService.write!(user: current_user, passport_hash: passport_input) unless passport_unchanged
          current_user.update!(
            passport_verified_at: Time.current,
            a1_verification_id: verification_id.to_s,
            phone: verified_phone
          )
          nil
        end

        def extract_passport_input
          passport_input = params[:passport]
          return nil unless passport_input.present?
          return nil unless passport_input.is_a?(Hash) || passport_input.is_a?(ActionController::Parameters)

          passport_input = passport_input.to_unsafe_h if passport_input.respond_to?(:to_unsafe_h)
          passport_input
        end

        def user_payload(user)
          {
            id: user.id,
            username: user.username,
            first_name: user.first_name,
            last_name: user.last_name,
            middle_name: user.middle_name,
            email: user.email,
            phone: user.phone,
            country_code: user.country_code,
            dob: user.dob,
            gender: user.gender,
            address: user.address,
            region: user.region,
            city: user.city,
            postcode: user.postcode,
            street: user.street,
            house: user.house,
            building: user.building,
            apartment: user.apartment,
            telegram_marketing: user.telegram_marketing,
            email_marketing: user.email_marketing,
            gdpr_consent: user.gdpr_consent,
            newsletter_consent: user.newsletter_consent,
            passport_verified: user.passport_verified?,
            passport_data: user.passport_data,
            a1_verification_id: user.a1_verification_id
          }
        end
      end
    end
  end
end
