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
          params.permit(:username, :email, :phone, :country_code, :gdpr_consent, :newsletter_consent)
        end

        def user_payload(user)
          {
            id: user.id,
            username: user.username,
            email: user.email,
            phone: user.phone,
            country_code: user.country_code,
            gdpr_consent: user.gdpr_consent,
            newsletter_consent: user.newsletter_consent,
            passport_verified: user.passport_verified?
          }
        end
      end
    end
  end
end
