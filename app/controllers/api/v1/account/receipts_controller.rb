module Api
  module V1
    module Account
      class ReceiptsController < ApplicationController
        include Rails.application.routes.url_helpers

        before_action :authenticate_user

        # GET /api/v1/account/receipts
        def index
          orders = current_user.orders.where.not(purchased_at: nil).order(purchased_at: :desc)
          data = orders.map do |order|
            {
              order_id: order.id,
              purchased_at: order.purchased_at.iso8601,
              receipts: order.receipts.map { |blob| receipt_payload(blob) }
            }
          end

          render json: { receipts: data }
        end

        private

        def receipt_payload(attachment)
          {
            filename: attachment.filename.to_s,
            content_type: attachment.content_type,
            byte_size: attachment.byte_size,
            url: rails_blob_url(attachment, host: request.base_url)
          }
        end
      end
    end
  end
end
