module Api
  module V1
    class CheckoutController < ApplicationController
      before_action :authenticate_user

      def create
        result = CheckoutService.call(user: current_user, params: checkout_params)
        
        if result[:success]
          render json: { 
            message: 'Заказ успешно оформлен', 
            order_id: result[:order].id,
            order: OrderSerializer.new(result[:order]).serializable_hash[:data][:attributes]
          }, status: :created
        else
          render json: result.except(:success), status: :unprocessable_entity
        end
      end

      private

      def checkout_params
        params.permit(
          :full_name,
          :phone,
          :delivery_type,
          :payment_method,
          :pickup_point_id,
          :delivery_address_id,
          :a1_verification_id,
          services: [],
          pickup_point: {},
          address: {},
          passport: {}
        )
      end
    end
  end
end
