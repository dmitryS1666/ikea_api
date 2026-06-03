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
        
        product = find_available_product_by_public_sku!(sku)

        favorite_item = favorite.favorite_items.find_or_initialize_by(product_sku: product.sku)
        favorite_item.save!

        favorite.touch_expiration!
        render json: favorite_response_payload(favorite, token)
      end

      def destroy
        authenticate_user_optional
        favorite, token, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
        sku = params[:id] # id is used in resources route for SKU
        
        favorite_item = favorite.favorite_items.find_by!(product_sku: sku_aliases_for_favorite(sku))
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

      private

      def find_available_product_by_public_sku!(sku)
        product = Products::ListingSkuResolver.find_product(sku)
        raise ActiveRecord::RecordNotFound, "Couldn't find Product" unless product&.available_in_stock?

        product
      end

      def sku_aliases_for_favorite(sku)
        Products::ListingSkuResolver.aliases(sku)
      end
    end
  end
end
