module Api
  module V1
    module Content
      class LegalPagesController < ApplicationController
        def index
          pages = LegalPage.for_public_api

          render json: LegalPageSerializer.new(pages)
        end

        def show
          slug = params[:slug] || params[:id]
          page = LegalPage.published.find_by!(slug: slug)

          render json: LegalPageSerializer.new(page, { params: { detail: true } })
        end
      end
    end
  end
end
