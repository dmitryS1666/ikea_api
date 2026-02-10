module Api
  module V1
    class A1VerificationsController < ApplicationController
      before_action :authenticate_user_optional

      # POST /api/v1/a1/request
      # Body: { phone: "+375...", context: "passport_update" }
      def request_call
        phone = params.require(:phone)
        context = params[:context].presence || 'passport_update'

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
          render json: { success: true }
        else
          render json: { success: false, error: result[:error] }, status: :unprocessable_entity
        end
      end

      private

      def authenticate_user_optional
        token = request.headers['Authorization']&.split(' ')&.last
        return unless token

        decoded = JwtService.decode(token)
        @current_user = User.find_by(id: decoded[:user_id]) if decoded
      end
    end
  end
end
