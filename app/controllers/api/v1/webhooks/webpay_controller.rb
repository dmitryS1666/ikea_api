module Api
  module V1
    module Webhooks
      class WebpayController < ApplicationController
        def create
          result = WebpayPaymentCompletionService.complete_from_notification(
            request.request_parameters,
            remote_ip: request.remote_ip
          )

          case result
          when :invalid_signature, :untrusted_ip
            head :forbidden
          when :paid, :already_paid, :already_paid_other, :ignored, :order_not_found,
               :amount_mismatch, :currency_mismatch, :invalid_state, :transaction_used,
               :remote_verify_failed, :invalid_transaction
            head :ok
          else
            head :ok
          end
        end
      end
    end
  end
end
