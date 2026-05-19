module Api
  module V1
    class ReturnRequestsController < ApplicationController
      include ReturnRequestResponse

      # POST /api/v1/return_requests — public storefront form (no JWT)
      def create
        result = ReturnRequests::CreateService.call(params: params)
        render_return_request_result(result)
      end
    end
  end
end
