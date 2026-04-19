module Api
  module V1
    class CooperationRequestsController < ApplicationController
      # Public endpoint (no JWT): form submission from frontend

      # POST /api/v1/cooperation_requests
      def create
        first_name = params[:first_name].presence || params[:name].to_s.split.first
        last_name = params[:last_name].presence || params[:name].to_s.split[1..]&.join(" ")
        comment = params[:comment].presence || params[:message]

        req = CooperationRequest.create!(
          name: [first_name, last_name].compact.join(" ").strip,
          first_name: first_name,
          last_name: last_name,
          phone: params[:phone],
          email: params[:email],
          company: params[:company],
          city: params[:city],
          cooperation_type: params.require(:cooperation_type),
          message: comment,
          comment: comment,
          personal_data_consent: ActiveModel::Type::Boolean.new.cast(params[:personal_data_consent]),
          marketing_email_consent: ActiveModel::Type::Boolean.new.cast(params[:marketing_email_consent])
        )

        render json: { cooperation_request: payload_for(req) }, status: :created
      end

      private

      def payload_for(r)
        {
          id: r.id,
          first_name: r.first_name,
          last_name: r.last_name,
          phone: r.phone,
          email: r.email,
          company: r.company,
          city: r.city,
          cooperation_type: r.cooperation_type,
          comment: r.comment,
          personal_data_consent: r.personal_data_consent,
          marketing_email_consent: r.marketing_email_consent,
          status: r.status,
          created_at: r.created_at.iso8601
        }
      end
    end
  end
end

