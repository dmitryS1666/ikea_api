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
            leads_list = if leads.respond_to?(:values) && !leads.is_a?(Array)
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

              # Amo sometimes nests one more level: { "0" => { real fields } }
              lead_data = normalize_lead_payload(lead_data)
              next unless lead_data.respond_to?(:[])

              crm_id = lead_data[:id] || lead_data['id']
              status_id = (lead_data[:status_id] || lead_data['status_id']).to_i

              order = Order.find_by(crm_external_id: crm_id.to_s)
              next unless order

              # Map AmoCRM status_id to internal order status (IDs must match your Amo pipeline columns)
              new_status = Order.statuses.key(status_id)
              if status_id.positive? && new_status.nil?
                Rails.logger.warn "[AmoCRM Webhook] Unmapped Amo status_id=#{status_id} for order_id=#{order.id} " \
                                  "(crm_external_id=#{crm_id}, current_status=#{order.status}). Add this id to Order enum or fix pipeline IDs."
              end

              update_params = {}
              update_params[:status] = new_status if new_status.present? && order.status != new_status

              merge_lead_custom_fields!(order, lead_data, update_params)

              if update_params.any?
                order.status_changed_at = parse_amo_timestamp(lead_data[:updated_at] || lead_data["updated_at"])
                order.status_change_source = "amo_webhook"
                order.status_change_raw_payload =
                  if lead_data.is_a?(ActionController::Parameters)
                    lead_data.to_unsafe_h
                  elsif lead_data.is_a?(Hash)
                    lead_data
                  else
                    {}
                  end
                if order.update(update_params)
                  Rails.logger.info "[AmoCRM Webhook] Order #{order.id} updated: #{update_params.keys.join(', ')}"
                else
                  Rails.logger.error "[AmoCRM Webhook] Order #{order.id} update failed: #{order.errors.full_messages.join('; ')}"
                end
              end
            end
          end
        end

        # Unwrap a single extra nesting level Amo occasionally sends.
        def normalize_lead_payload(lead_data)
          return lead_data unless lead_data.is_a?(Hash) || lead_data.is_a?(ActionController::Parameters)

          h = lead_data.is_a?(ActionController::Parameters) ? lead_data.to_unsafe_h : lead_data
          return lead_data if h['id'].present? || h[:id].present?
          return lead_data if h['status_id'].present? || h[:status_id].present?

          inner = h.values.first
          inner = inner.to_unsafe_h if inner.is_a?(ActionController::Parameters)
          (inner.is_a?(Hash) || inner.respond_to?(:[])) ? inner : lead_data
        end

        def merge_lead_custom_fields!(order, lead_data, update_params)
          fields = lead_data[:custom_fields_values].presence || lead_data['custom_fields_values'].presence ||
                   lead_data[:custom_fields].presence || lead_data['custom_fields'].presence
          return if fields.blank?

          Array(fields).each do |cf|
            next unless cf.respond_to?(:[])

            field_id = (cf[:field_id] || cf['field_id'] || cf[:id] || cf['id']).to_i
            next if field_id.zero?

            raw_values = cf[:values] || cf['values']
            first = Array(raw_values).first
            value = if first.is_a?(Hash)
                      first[:value] || first['value']
                    else
                      first
                    end
            next if value.blank?

            case field_id
            when 363_323 # WEIGHT
              new_val = value.to_f
              update_params[:weight] = new_val if order.weight != new_val
            when 377_661 # TRACK_NUMBER
              update_params[:track_number] = value if order.track_number != value
            when 578_819 # CANCELLATION_REASON
              update_params[:cancellation_reason] = value if order.cancellation_reason != value
            end
          end
        rescue StandardError => e
          Rails.logger.error "[AmoCRM Webhook] custom fields parse error for order #{order.id}: #{e.message}"
        end

        def parse_amo_timestamp(value)
          return nil if value.blank?

          # Amo webhooks often pass unix timestamp.
          return Time.zone.at(value.to_i) if value.to_s.match?(/\A\d+\z/)

          Time.zone.parse(value.to_s)
        rescue StandardError
          nil
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
