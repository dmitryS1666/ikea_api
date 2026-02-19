module Api
  module V1
    module Debug
      class AmoCrmController < ApplicationController
        # Only for debug purposes, should be protected in production
        # before_action :authenticate_admin!

        # POST /api/v1/debug/amo_crm/sync_order/:id
        def sync_order
          order = Order.find(params[:id])
          result = CrmIntegrationService.sync_order(order)
          
          if result[:success]
            render json: { success: true, message: "Order synced successfully", crm_id: order.crm_external_id, data: result[:lead_id] }
          else
            render json: { success: false, message: "Sync failed", error: result[:error], code: result[:code] }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/debug/amo_crm/sync_user/:id
        def sync_user
          user = User.find(params[:id])
          result = CrmIntegrationService.sync_user(user)
          
          if result[:success]
            render json: { success: true, message: "User synced successfully", data: result[:data] }
          else
            render json: { success: false, message: "Sync failed", error: result[:error], code: result[:code] }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/debug/amo_crm/exchange_token
        def exchange_token
          code = params.require(:code)
          result = CrmIntegrationService.exchange_code_for_tokens(code)
          
          if result[:success]
            render json: { success: true, tokens: result[:tokens] }
          else
            render json: { success: false, message: "Token exchange failed", error: result[:error], code: result[:code] }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
