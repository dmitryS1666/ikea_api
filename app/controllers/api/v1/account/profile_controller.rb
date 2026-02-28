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

          # Handle passport update separately
          if params[:passport].is_a?(Hash)
            passport_input = params[:passport]
            current_passport = current_user.passport_data
            
            if !UserPassportService.same?(passport_input, current_passport)
              UserPassportService.write!(user: current_user, passport_hash: passport_input)
              current_user.update!(passport_verified_at: nil) # Reset verification when changed
            end
          end

          if current_user.update(profile_params)
            # Передача данных в CRM (заглушка)
            CrmIntegrationService.sync_user(current_user)
            render json: user_payload(current_user)
          else
            render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def profile_params
          params.permit(
            :username, :email, :phone, :country_code, 
            :gdpr_consent, :newsletter_consent,
            :dob, :gender, :address, 
            :telegram_marketing, :email_marketing
          )
        end

        def user_payload(user)
          {
            id: user.id,
            username: user.username,
            email: user.email,
            phone: user.phone,
            country_code: user.country_code,
            dob: user.dob,
            gender: user.gender,
            address: user.address,
            telegram_marketing: user.telegram_marketing,
            email_marketing: user.email_marketing,
            gdpr_consent: user.gdpr_consent,
            newsletter_consent: user.newsletter_consent,
            passport_verified: user.passport_verified?,
            passport_data: user.passport_data
          }
        end
      end
    end
  end
end
