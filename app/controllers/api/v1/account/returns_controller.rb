module Api
  module V1
    module Account
      class ReturnsController < ApplicationController
        before_action :authenticate_user

        # GET /api/v1/account/returns
        def index
          requests = current_user.return_requests.includes(:order).ordered
          paginated = requests.page(params[:page]).per(params[:per_page] || 10)

          render json: {
            returns: paginated.map { |r| payload_for(r) },
            meta: { total: paginated.total_count, page: params[:page] || 1, per_page: params[:per_page] || 10 }
          }
        end

        # POST /api/v1/account/returns
        # Content-Type: multipart/form-data is supported for attachments[]
        def create
          order = Order.find_for_account!(current_user, params.require(:order_id))
          req = current_user.return_requests.create!(
            order: order,
            reason: params.require(:reason),
            comment: params[:comment]
          )
          if params[:attachments].present?
            Array(params[:attachments]).each { |f| req.attachments.attach(f) }
          end

          render json: { return_request: payload_for(req) }, status: :created
        end

        private

        def payload_for(r)
          {
            id: r.id,
            order_id: r.order_id,
            status: r.status,
            reason: r.reason,
            comment: r.comment,
            created_at: r.created_at.iso8601,
            attachments_count: r.attachments.count
          }
        end
      end
    end
  end
end
