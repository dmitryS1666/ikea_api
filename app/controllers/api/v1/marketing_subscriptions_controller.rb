# frozen_string_literal: true

module Api
  module V1
    class MarketingSubscriptionsController < ApplicationController
      # POST /api/v1/marketing/unsubscribe
      def unsubscribe
        result = MarketingUnsubscribeService.unsubscribe_by_token!(params[:token])
        render json: result, status: :ok
      rescue MarketingUnsubscribeService::InvalidToken
        render json: {
          success: false,
          status: "invalid_token",
          message: "Ссылка для отписки недействительна"
        }, status: :unprocessable_content
      end
    end
  end
end
