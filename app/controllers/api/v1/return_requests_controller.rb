module Api
  module V1
    class ReturnRequestsController < ApplicationController
      # Public endpoint (no JWT): «Заявка на возврат товара» on the storefront.

      # POST /api/v1/return_requests
      def create
        order = find_order_by_number!(order_number_param)
        req = ReturnRequest.create!(
          order: order,
          user: order.user,
          first_name: first_name_param,
          patronymic: params[:patronymic].presence || params[:middle_name],
          order_number: order_number_param,
          phone: params[:phone],
          email: params[:email],
          reason: params.require(:reason),
          comment: params[:comment],
          compensation_type: compensation_type_param
        )
        attach_files!(req)

        render json: { return_request: payload_for(req) }, status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Заказ не найден" }, status: :not_found
      end

      private

      def order_number_param
        raw = params[:order_number].presence || params[:order_id].presence || params[:order_num]
        raw.to_s.strip
      end

      def first_name_param
        params[:first_name].presence || params[:name].to_s.split.first
      end

      def compensation_type_param
        raw = params[:compensation_type].presence || params[:compensation_method].presence ||
              params[:preferred_compensation]
        return "exchange" if raw.to_s.match?(/обмен/i)
        return "refund" if raw.to_s.match?(/возврат|refund/i)

        raw
      end

      def find_order_by_number!(number)
        raise ActiveRecord::RecordNotFound if number.blank?

        if number.match?(Order::PUBLIC_UID_FORMAT)
          Order.find_by!(public_uid: number)
        else
          Order.find_by!(id: number)
        end
      end

      def attach_files!(req)
        files = params[:attachments].presence || params[:photos].presence || params[:files]
        return if files.blank?

        Array(files).each { |f| req.attachments.attach(f) }
      end

      def payload_for(r)
        {
          id: r.id,
          order_id: r.order_id,
          order_number: r.order_number,
          status: r.status,
          reason: r.reason,
          comment: r.comment,
          compensation_type: r.compensation_type,
          created_at: r.created_at.iso8601,
          attachments_count: r.attachments.count
        }
      end
    end
  end
end
