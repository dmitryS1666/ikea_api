module Api
  module V1
    module Account
      class ReturnsController < ApplicationController
        include ReturnRequestResponse

        before_action :authenticate_user, only: [:index]
        before_action :authenticate_user_optional, only: [:create]

        # GET /api/v1/account/returns
        def index
          requests = current_user.return_requests.includes(:order).ordered
          paginated = requests.page(params[:page]).per(params[:per_page] || 10)

          render json: {
            returns: paginated.map { |r| return_request_payload(r) },
            meta: { total: paginated.total_count, page: params[:page] || 1, per_page: params[:per_page] || 10 }
          }
        end

        # POST /api/v1/account/returns
        # JWT optional: storefront return modal posts here without Authorization.
        # Content-Type: multipart/form-data is supported for attachments[]
        def create
          result = ReturnRequests::CreateService.call(params: params, user: current_user)
          render_return_request_result(result)
        end
      end
    end
  end
end
