module Api
  module V1
    class FavoritesController < ApplicationController
      include FavoriteResponseFormatter

      def show
        authenticate_user_optional
        favorite, token, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
        favorite.touch_expiration!
        render json: favorite_response_payload(favorite, token)
      end

      def create
        authenticate_user_optional
        favorite, token, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
        sku = params.require(:sku)
        
        # Verify product exists
        Product.with_available_stock.find_by!(sku: sku)

        favorite_item = favorite.favorite_items.find_or_initialize_by(product_sku: sku)
        favorite_item.save!

        favorite.touch_expiration!
        render json: favorite_response_payload(favorite, token)
      end

      def destroy
        authenticate_user_optional
        favorite, token, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
        sku = params[:id] # id is used in resources route for SKU
        
        favorite_item = favorite.favorite_items.find_by!(product_sku: sku)
        favorite_item.destroy!

        favorite.touch_expiration!
        render json: favorite_response_payload(favorite, token)
      end

      def clear
        authenticate_user_optional
        favorite, token, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
        favorite.favorite_items.destroy_all
        favorite.touch_expiration!
        render json: favorite_response_payload(favorite, token)
      end
    end
  end
end
