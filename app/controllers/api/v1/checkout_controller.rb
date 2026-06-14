module Api
  module V1
    class CheckoutController < ApplicationController
      before_action :authenticate_user
      before_action :set_draft_order, only: [:show, :update, :finalize, :destroy]

      def create
        result = CheckoutService.call(user: current_user, params: checkout_params)

        if result[:success]
          status = result[:reused] ? :ok : :created
          render json: success_payload(result), status: status
        else
          render_error(result)
        end
      end

      def draft
        draft_id = params[:draft_id].presence || params[:id].presence
        @draft_order = current_user.orders.find_by(id: draft_id, checkout_draft: true)

        unless @draft_order
          return render json: { error: 'Черновик заказа не найден', code: 'draft_not_found' }, status: :not_found
        end

        render json: checkout_order_payload(@draft_order), status: :ok
      end

      def show
        render json: checkout_order_payload(@draft_order), status: :ok
      end

      def update
        result = CheckoutService.update_draft(user: current_user, order_id: @draft_order.id, params: checkout_params)

        if result[:success]
          render json: checkout_order_payload(result[:order], pricing: result[:pricing]), status: :ok
        else
          render_error(result)
        end
      end

      def finalize
        result = CheckoutService.finalize(user: current_user, order_id: @draft_order.id, params: checkout_params)

        if result[:success]
          render json: success_payload(result), status: :created
        else
          render_error(result)
        end
      end

      def destroy
        result = CheckoutService.cancel_draft(user: current_user, order_id: @draft_order.id)

        if result[:success]
          head :no_content
        else
          render_error(result)
        end
      end

      private

      def set_draft_order
        @draft_order = current_user.orders.find_by(id: params[:id], checkout_draft: true)
        return if @draft_order

        render json: { error: 'Черновик заказа не найден', code: 'draft_not_found' }, status: :not_found
        throw :abort
      end

      def success_payload(result)
        order = result[:order]
        message = order.checkout_draft ? 'Черновик заказа создан' : 'Заказ успешно оформлен'

        payload = {
          message: message,
          order_id: order.id,
          order: OrderSerializer.new(order).serializable_hash[:data][:attributes]
        }

        if order.checkout_draft
          payload[:id] = order.id
          payload[:draft_id] = order.id
          payload[:draft_order_id] = order.id
        end

        if order.checkout_draft && result[:delivery_options].present?
          payload[:delivery_options] = result[:delivery_options]
        end

        if order.checkout_draft
          payload[:pricing] = result[:pricing] || CheckoutPricingPresenter.for_order(order)
        end

        payload[:reused] = true if result[:reused]

        payload
      end

      def checkout_order_payload(order, pricing: nil)
        payload = OrderSerializer.new(order, include: [:order_items]).serializable_hash

        if order.checkout_draft?
          payload[:pricing] = pricing || CheckoutPricingPresenter.for_order(order)
        end

        payload
      end

      def render_error(result)
        body = result.except(:success)
        status =
          case result[:code]
          when 'checkout_draft_exists'
            :conflict
          when 'draft_not_found'
            :not_found
          else
            :unprocessable_entity
          end
        render json: body, status: status
      end

      def checkout_params
        params.permit(
          :draft,
          :full_name,
          :phone,
          :delivery_type,
          :payment_method,
          :pickup_point_id,
          :delivery_address_id,
          :a1_verification_id,
          :a1_verification_last4,
          :verification_code,
          :cart_token,
          services: [],
          pickup_point: {},
          address: {},
          passport: {},
          items: [:sku, :quantity]
        )
      end
    end
  end
end
