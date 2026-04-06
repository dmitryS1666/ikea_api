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
          leads_params.each do |action, leads|
            # leads is usually a Hash/Parameters object with indices as keys: {"0"=>{"id"=>...}, "1"=>{"id"=>...}}
            # but it could theoretically be an Array
            leads_list = if leads.respond_to?(:values)
                           leads.values
                         elsif leads.respond_to?(:each_value)
                           values = []
                           leads.each_value { |v| values << v }
                           values
                         else
                           Array(leads)
                         end
            
            leads_list.each do |lead_data|
              next unless lead_data.respond_to?(:[])
              
              crm_id = lead_data[:id] || lead_data['id']
              status_id = (lead_data[:status_id] || lead_data['status_id']).to_i
              
              order = Order.find_by(crm_external_id: crm_id.to_s)
              next unless order
              
              # Map AmoCRM status_id to internal order status
              new_status = Order.statuses.key(status_id)
              
              if new_status
                if order.status != new_status
                  order.update(status: new_status)
                  Rails.logger.info "[AmoCRM Webhook] Order #{order.id} status updated to #{new_status} (Amo ID: #{status_id})"
                end
              else
                Rails.logger.warn "[AmoCRM Webhook] Unknown status_id #{status_id} for Lead #{crm_id}"
              end
            end
          end
        end

        def handle_contacts_webhook(contacts_params)
          # Handle contact updates if needed
          contacts_list = if contacts_params.respond_to?(:values)
                            contacts_params.values
                          elsif contacts_params.respond_to?(:each_value)
                            values = []
                            contacts_params.each_value { |v| values << v }
                            values
                          else
                            Array(contacts_params)
                          end
          
          contacts_list.each do |action_data|
            # ...
          end
          
          Rails.logger.info "[AmoCRM Webhook] Contact update received"
        end
      end
    end
  end
end
