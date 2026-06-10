module Api
  module V1
    class CartPromoController < ApplicationController
      include CartResponseFormatter

      def apply
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        code = params.require(:code).strip.upcase
        promo = PromoCode.find_by(code: code)

        unless promo&.active_now?
          return render json: { error: 'invalid_promo_code' }, status: :unprocessable_entity
        end

        if CartSelectionService.items_key_present?(params)
          selections = CartSelectionService.parse_items_param(params)
          if selections.blank?
            return render json: { error: 'Корзина пуста', code: 'cart_empty' }, status: :unprocessable_entity
          end

          result = CartSummaryService.call(cart: cart, items: selections, promo_code: code)
          return render json: result.except(:success), status: :unprocessable_entity if result[:error]

          return render json: result.except(:error, :code), status: :ok
        end

        cart.update!(promo_code: promo)
        cart.touch_expiration!

        render json: cart_response_payload(cart, token)
      end

      def remove
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        cart.update!(promo_code_id: nil)
        cart.touch_expiration!

        render json: cart_response_payload(cart, token)
      end
    end
  end
end
