module Api
  module V1
    class CartSummaryController < ApplicationController
      def create
        authenticate_user_optional
        cart, = CartTokenResolver.call(request: request, params: params, user: current_user)
        return render json: { error: 'Корзина не найдена' }, status: :not_found unless cart

        selections = CartSelectionService.parse_items_param(params)
        if selections.blank?
          return render json: { error: 'Укажите items для расчёта', code: 'items_required' }, status: :unprocessable_entity
        end

        result = CartSummaryService.call(cart: cart, items: selections)
        if result[:error]
          status = result[:code] == 'item_not_in_cart' ? :unprocessable_entity : :unprocessable_entity
          render json: result.except(:success), status: status
        else
          render json: result.except(:error, :code), status: :ok
        end
      end
    end
  end
end
