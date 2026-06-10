module Api
  module V1
    module Account
      class OrdersController < ApplicationController
        before_action :authenticate_user

        def index
          orders = current_user.orders.includes(order_items: :product).order(created_at: :desc)
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
          cart = current_user.cart || current_user.create_cart

          added_items = []
          missing_items = []

          order.order_items.each do |item|
            product = Product.with_available_stock.find_by(sku: item.product_sku)
            if product
              cart_item = cart.cart_items.find_or_initialize_by(product_sku: item.product_sku)
              cart_item.quantity = (cart_item.quantity || 0) + item.quantity
              cart_item.save!
              added_items << item.product_sku
            else
              missing_items << item.product_sku
            end
          end

          render json: {
            message: 'Товары добавлены в корзину',
            added_skus: added_items,
            missing_skus: missing_items,
            has_missing: missing_items.any?
          }
        end
      end
    end
  end
end
