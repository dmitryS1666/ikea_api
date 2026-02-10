module Api
  module V1
    class CartItemsController < ApplicationController
      include CartResponseFormatter

      def create
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        sku = params.require(:sku)
        quantity = params.require(:quantity).to_i
        Product.find_by!(sku: sku)

        cart_item = cart.cart_items.find_or_initialize_by(product_sku: sku)
        cart_item.quantity = cart_item.quantity.to_i + quantity
        cart_item.save!

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end

      def update
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        sku = params[:sku]
        quantity = params.require(:quantity).to_i
        cart_item = cart.cart_items.find_by!(product_sku: sku)

        if quantity <= 0
          cart_item.destroy!
        else
          cart_item.update!(quantity: quantity)
        end

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end

      def destroy
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        sku = params[:sku]
        cart_item = cart.cart_items.find_by!(product_sku: sku)
        cart_item.destroy!

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end

      # DELETE /api/v1/cart_items
      # Body:
      # { "skus": ["123.456.78"...]}  or { "delete_all": true }
      def bulk_destroy
        cart, token, _ = CartTokenResolver.call(request: request, params: params)

        if params[:delete_all].to_s == 'true'
          cart.cart_items.destroy_all
        else
          skus = Array(params[:skus]).map(&:to_s).map(&:strip).reject(&:empty?)
          return render json: { error: 'skus is required' }, status: :unprocessable_entity if skus.empty?

          cart.cart_items.where(product_sku: skus).destroy_all
        end

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end
    end
  end
end
