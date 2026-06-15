module Api
  module V1
    class CartSummaryController < ApplicationController
      include CartResponseFormatter

      def create
        authenticate_user_optional
        cart, token = CartTokenResolver.call(request: request, params: params, user: current_user)
        return render json: { error: 'Корзина не найдена' }, status: :not_found unless cart

        selections = CartSelectionService.parse_items_param(params)
        if selections.blank?
          return render json: { error: 'Корзина пуста', code: 'cart_empty' }, status: :unprocessable_entity
        end

        built = CartSelectionService.build_subset_cart(cart: cart, selections: selections)
        if built[:error]
          return render json: built.except(:cart, :selections), status: :unprocessable_entity
        end

        result = CartSummaryService.call(cart: cart, items: selections, promo_code: params[:promo_code])
        if result[:error]
          status = result[:code] == 'item_not_in_cart' ? :unprocessable_entity : :unprocessable_entity
          render json: result.except(:success), status: status
        else
          render json: summary_response_payload(cart, token, result, pricing_cart: built[:cart]), status: :ok
        end
      end
    end
  end
end
