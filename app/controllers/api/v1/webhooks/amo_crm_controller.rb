module Api
  module V1
    module Webhooks
      class AmoCrmController < ApplicationController
        skip_before_action :verify_authenticity_token if respond_to?(:verify_authenticity_token)
        
        # POST /api/v1/webhooks/amo_crm
        def receive
          # Log the incoming webhook for debugging
          raw_body = request.raw_post
          Rails.logger.info "[AmoCRM Webhook] Params: #{params.to_unsafe_h.inspect}"
          Rails.logger.info "[AmoCRM Webhook] Raw Body: #{raw_body}"
          
          # Handle specific events from AmoCRM
          # Documentation: https://www.amocrm.ru/developers/content/webhooks/webhooks
          
          # AmoCRM sends data in a nested format, e.g., leads[update][0][id]
          # Rails might parse this into params[:leads][:update]...
          
          if params[:leads]
            handle_leads_webhook(params[:leads])
          elsif params[:contacts]
            handle_contacts_webhook(params[:contacts])
          end

          render json: { status: 'ok' }, status: :ok
        end

        private

        def handle_leads_webhook(leads_params)
          # Example: update order status when lead status changes in AmoCRM
          # leads_params is usually a hash like {"status": [{"id": "123", "status_id": "456", ...}]}
          leads_params.each do |action, leads|
            leads.each do |lead_data|
              crm_id = lead_data[:id]
              status_id = lead_data[:status_id]
              
              order = Order.find_by(crm_external_id: crm_id)
              next unless order
              
              # Map AmoCRM status_id to internal order status if needed
              # order.update(status: map_amo_status(status_id))
              Rails.logger.info "[AmoCRM Webhook] Lead #{crm_id} action: #{action}, status: #{status_id}"
            end
          end
        end

        def handle_contacts_webhook(contacts_params)
          # Handle contact updates if needed
          Rails.logger.info "[AmoCRM Webhook] Contact update received"
        end
      end
    end
  end
end
