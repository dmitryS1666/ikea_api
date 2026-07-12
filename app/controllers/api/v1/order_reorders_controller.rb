# frozen_string_literal: true

module Api
  module V1
    class OrderReordersController < ApplicationController
      # One-click signed link from the cancellation email. The service updates
      # the authenticated owner's server-side cart and then opens the cart UI.
      def show
        order = OrderReorderLinkService.order_from_token!(params[:token])
        result = OrderReorderService.call(order: order, user: order.user)

        redirect_to cart_url(result), allow_other_host: true
      rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound => e
        Rails.logger.warn("[OrderReorder] Invalid email link: #{e.class} #{e.message}")
        redirect_to "#{Seo::PublicSiteUrl.resolve}/cart?reorder=invalid", allow_other_host: true
      end

      private

      def cart_url(result)
        status = result[:has_missing] ? "partial" : "updated"
        "#{Seo::PublicSiteUrl.resolve}/cart?reorder=#{status}"
      end
    end
  end
end
