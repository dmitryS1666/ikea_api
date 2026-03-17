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

        # Throttle: 30 seconds between requests
        last_verification = A1Verification.where(phone: phone).order(created_at: :desc).first
        if last_verification && last_verification.created_at > 30.seconds.ago
          seconds_left = (last_verification.created_at + 30.seconds - Time.current).to_i
          return render json: { 
            error: "Повторный запрос звонка возможен через #{seconds_left} сек.",
            seconds_left: seconds_left
          }, status: :too_many_requests
        end

        payload = A1StubService.request_call(user: current_user, phone: phone, context: context)
        render json: payload, status: :created
      end

      # POST /api/v1/a1/verify
      # Body: { verification_id: 123, last4: "1234" }
      def verify_call
        verification_id = params.require(:verification_id)
        last4 = params.require(:last4)

        result = A1StubService.verify_call(verification_id: verification_id, last4: last4)
        if result[:success]
          # If it was a passport update, update the user's passport_verified_at
          verification = A1Verification.find(verification_id)
          
          # Security check: if user is logged in, ensure this verification belongs to them
          # Or if they are anonymous (checkout), it still works
          if verification.context == 'passport_update' && verification.user.present?
            if current_user.nil? || current_user.id == verification.user_id
              verification.user.update!(passport_verified_at: Time.current)
            end
          end

          render json: { success: true }
        else
          render json: { success: false, error: result[:error] }, status: :unprocessable_entity
        end
      end
    end
  end
end
