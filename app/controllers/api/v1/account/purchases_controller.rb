module Api
  module V1
    module Account
      class PurchasesController < ApplicationController
        before_action :authenticate_user

        # GET /api/v1/account/purchases
        # Optional params:
        # - sort: newest|oldest|price_asc|price_desc
        def index
          orders = current_user.orders.purchased.includes(:order_items).order(purchased_at: :desc, created_at: :desc)

          items = orders.flat_map do |order|
            order.order_items.map do |oi|
              product = Product.find_by(sku: oi.product_sku)
              {
                order_id: order.id,
                status: order.frontend_status,
                purchased_at: order.purchased_at&.iso8601,
                product_sku: oi.product_sku,
                quantity: oi.quantity,
                price_byn: sprintf('%.2f', oi.price.to_f),
                product: product ? {
                  sku: product.sku,
                  name: product.name,
                  price_byn: sprintf('%.2f', product.price.to_f),
                  images: {
                    local_images: ProductLocalImages.preview_paths(product.local_images || []),
                    images: product.images || []
                  }
                } : nil
              }
            end
          end

          items = sort_items(items, params[:sort])

          page = (params[:page] || 1).to_i
          per_page = (params[:per_page] || 20).to_i
          total = items.size
          paginated = items.slice((page - 1) * per_page, per_page) || []

          render json: {
            purchases: paginated,
            meta: { total: total, page: page, per_page: per_page, sort: params[:sort] }
          }
        end

        private

        def sort_items(items, sort)
          case sort.to_s
          when 'oldest'
            items.sort_by { |i| i[:purchased_at].to_s }
          when 'price_asc'
            items.sort_by { |i| i[:price_byn].to_f }
          when 'price_desc'
            items.sort_by { |i| -i[:price_byn].to_f }
          else
            # newest
            items.sort_by { |i| i[:purchased_at].to_s }.reverse
          end
        end
      end
    end
  end
end
