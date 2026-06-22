module Api
  module V1
    module Webhooks
      class SendpulseController < ApplicationController
        # POST /api/v1/webhooks/sendpulse
        # Scaffold for future SendPulse unsubscribe / list events.
        def create
          payload = webhook_payload
          event = payload["event"].to_s

          if unsubscribe_event?(event)
            result = Sendpulse::UnsubscribeHandler.call(payload)
            render json: result, status: result[:success] ? :ok : :unprocessable_entity
          else
            render json: { success: true, ignored: true, event: event.presence || "unknown" }, status: :ok
          end
        end

        private

        def webhook_payload
          raw = request.request_parameters
          return raw if raw.present?

          JSON.parse(request.raw_post)
        rescue JSON::ParserError
          {}
        end

        def unsubscribe_event?(event)
          event.in?(%w[unsubscribe unsubscribe_email global_unsubscribe])
        end
      end
    end
  end
end
