module Api
  module V1
    module Webhooks
      class SendpulseController < ApplicationController
        # POST /api/v1/webhooks/sendpulse
        def create
          payload = webhook_payload

          if smtp_events?(payload)
            result = Sendpulse::SmtpEventHandler.call(payload)
            render json: result, status: :ok
            return
          end

          event = payload.is_a?(Hash) ? payload["event"].to_s : ""
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
          return raw["_json"] if raw.is_a?(Hash) && raw.key?("_json")
          return raw if raw.present?

          JSON.parse(request.raw_post)
        rescue JSON::ParserError
          {}
        end

        def smtp_events?(payload)
          events = payload.is_a?(Array) ? payload : [payload]
          events.any? do |item|
            next false unless item.is_a?(Hash)

            event = item["event"].to_s
            Sendpulse::SmtpEventHandler::TRACKED_EVENTS.include?(event)
          end
        end

        def unsubscribe_event?(event)
          event.in?(%w[unsubscribe unsubscribe_email global_unsubscribe])
        end
      end
    end
  end
end
