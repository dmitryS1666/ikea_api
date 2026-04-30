module Api
  module V1
    class PaymentLinksController < ApplicationController
      skip_before_action :authenticate_user

      def show
        return render_not_found unless order.present?
        return render_invalid_token unless valid_token?
        return render_expired if order.payment_expires_at.blank? || order.payment_expires_at < Time.current

        form = WebpayPaymentLinkService.build_form(order: order)
        render body: build_payment_page_html(form), content_type: 'text/html'
      end

      private

      def build_payment_page_html(form)
        fields_html = form.fields.map do |name, value|
          %(<input type="hidden" name="#{ERB::Util.html_escape(name)}" value="#{ERB::Util.html_escape(value)}" />)
        end.join("\n")

        <<~HTML
          <!DOCTYPE html>
          <html>
            <head>
              <meta charset="UTF-8" />
              <title>Open Webpay</title>
            </head>
            <body>
              <p>Перенаправляем на безопасную страницу оплаты WEBPAY...</p>
              <p>Если переход не начался автоматически, нажмите кнопку ниже.</p>
              <form id="webpay-form" action="#{ERB::Util.html_escape(form.action)}" method="post">
                #{fields_html}
                <button type="submit">Перейти к оплате</button>
              </form>
              <script>
                document.addEventListener('DOMContentLoaded', function () {
                  document.getElementById('webpay-form')?.submit();
                });
              </script>
            </body>
          </html>
        HTML
      end

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
