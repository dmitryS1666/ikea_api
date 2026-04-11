module Api
  module V1
    class PaymentLinksController < ApplicationController
      skip_before_action :authenticate_user

      def show
        return render_not_found unless order.present?
        return render_invalid_token unless valid_token?
        return render_expired if order.payment_expires_at.blank? || order.payment_expires_at < Time.current

        form = WebpayPaymentLinkService.build_form(order: order)
        render template: 'api/v1/payment_links/show', locals: { form: form }, layout: false
      end

      private

      def order
        @order ||= Order.find_by(id: params[:id])
      end

      def valid_token?
        return false if params[:token].blank? || order.payment_link_token.blank?

        ActiveSupport::SecurityUtils.secure_compare(order.payment_link_token, params[:token])
      end

      def render_not_found
        render json: { error: 'Ссылка на оплату не найдена' }, status: :not_found
      end

      def render_invalid_token
        render json: { error: 'Недействительная ссылка на оплату' }, status: :forbidden
      end

      def render_expired
        render json: { error: 'Ссылка для оплаты устарела' }, status: :gone
      end
    end
  end
end
