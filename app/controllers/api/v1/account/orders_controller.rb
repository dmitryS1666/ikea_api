module Api
  module V1
    module Account
      class OrdersController < ApplicationController
        before_action :authenticate_user

        def index
          Order.cancel_expired_unpaid_for_relation!(current_user.orders)
          orders = current_user.orders.visible_in_account_list.includes(order_items: :product).order(created_at: :desc)
          paginated = orders.page(params[:page]).per(params[:per_page] || 10)

          render json: OrderSerializer.new(paginated, {
            include: [:order_items],
            meta: {
              total: paginated.total_count,
              page: params[:page] || 1,
              per_page: params[:per_page] || 10
            }
          })
        end

        def show
          Order.cancel_expired_unpaid_for_relation!(current_user.orders)
          order = Order.find_for_account!(current_user, params[:id])
          render json: OrderSerializer.new(order, include: [:order_items])
        end

        # POST /api/v1/account/orders/:id/confirm_webpay
        # JSON: { "transaction_id": "<wsb_tid из return URL WebPay>" } — если серверный notify недоступен.
        def confirm_webpay
          order = Order.find_for_account!(current_user, params[:id])
          tid = params.permit(:transaction_id)[:transaction_id].presence
          unless tid.present?
            render json: { error: 'Укажите transaction_id' }, status: :unprocessable_entity
            return
          end

          unless WebpayGetTransactionService.billing_configured?
            render json: {
              error: 'Подтверждение через Billing API недоступно. Задайте WEBPAY_BILLING_USERNAME и WEBPAY_BILLING_PASSWORD.'
            }, status: :service_unavailable
            return
          end

          result = WebpayPaymentCompletionService.complete_for_order_with_transaction!(order: order, transaction_id: tid)

          case result
          when :paid
            render json: {
              message: 'Оплата подтверждена',
              order: OrderSerializer.new(order.reload).serializable_hash[:data][:attributes]
            }, status: :ok
          when :already_paid, :already_paid_other
            render json: {
              message: 'Заказ уже оплачен',
              order: OrderSerializer.new(order.reload).serializable_hash[:data][:attributes]
            }, status: :ok
          when :remote_failed
            render json: { error: 'Не удалось получить статус транзакции в WebPay' }, status: :bad_gateway
          when :invalid_signature, :not_paid
            render json: { error: 'Платёж не подтверждён' }, status: :unprocessable_entity
          when :amount_mismatch, :currency_mismatch
            render json: { error: 'Сумма или валюта не совпадают с заказом' }, status: :unprocessable_entity
          when :transaction_used
            render json: { error: 'Транзакция уже привязана к другому заказу' }, status: :conflict
          when :invalid_state
            render json: { error: 'Заказ нельзя оплатить в текущем статусе' }, status: :unprocessable_entity
          else
            render json: { error: 'Не удалось подтвердить оплату' }, status: :unprocessable_entity
          end
        end

        def reorder
          order = Order.find_for_account!(current_user, params[:id])
          result = OrderReorderService.call(order: order, user: current_user)

          render json: {
            message: 'Корзина обновлена',
            added_skus: result[:added_skus],
            updated_skus: result[:updated_skus],
            missing_skus: result[:missing_skus],
            adjusted_items: result[:adjusted_items],
            has_missing: result[:has_missing]
          }
        end
      end
    end
  end
end
