module Api
  module V1
    module Account
      class OrdersController < ApplicationController
        before_action :authenticate_user

        def index
          orders = current_user.orders.order(created_at: :desc)
          paginated = orders.page(params[:page]).per(params[:per_page] || 10)

          render json: OrderSerializer.new(paginated, {
            meta: {
              total: paginated.total_count,
              page: params[:page] || 1,
              per_page: params[:per_page] || 10
            }
          })
        end

        def show
          order = current_user.orders.find(params[:id])
          render json: OrderSerializer.new(order, include: [:order_items])
        end

        # POST /api/v1/account/orders/:id/reorder
        def reorder
          order = current_user.orders.find(params[:id])
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
