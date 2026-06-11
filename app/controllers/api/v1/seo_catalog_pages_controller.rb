# frozen_string_literal: true

module Api
  module V1
    class SeoCatalogPagesController < ApplicationController
      def index
        pages = sitemap_request? ? SeoCatalogPage.for_sitemap : SeoCatalogPage.for_frontend

        render json: {
          data: pages.map(&:frontend_list_payload)
        }
      end

      def show
        page = SeoCatalogPage.published.find_by!(slug: params[:slug].to_s)

        render json: {
          data: page.frontend_detail_payload
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "SEO catalog page not found" }, status: :not_found
      end

      private

      def sitemap_request?
        ActiveModel::Type::Boolean.new.cast(params[:sitemap] || params[:for_sitemap])
      end
    end
  end
end
