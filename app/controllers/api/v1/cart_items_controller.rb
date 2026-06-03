module Api
  module V1
    class CartItemsController < ApplicationController
      include CartResponseFormatter

      def create
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        sku = params.require(:sku)
        quantity = params.require(:quantity).to_i
        product = find_available_product_by_public_sku!(sku)

        cart_item = cart.cart_items.find_or_initialize_by(product_sku: product.sku)
        if cart_item.new_record?
          cart_item.quantity = quantity
        else
          cart_item.quantity = cart_item.quantity.to_i + quantity
        end
        cart_item.save!

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end

      def update
        cart, token, _ = CartTokenResolver.call(request: request, params: params)
        sku = params[:sku]
        quantity = params.require(:quantity).to_i
        cart_item = find_cart_item_by_public_sku!(cart, sku)

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
        cart_item = find_cart_item_by_public_sku!(cart, sku)
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

          cart.cart_items.where(product_sku: sku_aliases_for_cart(skus)).destroy_all
        end

        cart.touch_expiration!
        render json: cart_response_payload(cart, token)
      end

      private

      def find_available_product_by_public_sku!(sku)
        product = Products::ListingSkuResolver.find_product(sku)
        raise ActiveRecord::RecordNotFound, "Couldn't find Product" unless product&.available_in_stock?

        product
      end

      def find_cart_item_by_public_sku!(cart, sku)
        cart.cart_items.find_by!(product_sku: sku_aliases_for_cart(sku))
      end

      def sku_aliases_for_cart(skus)
        Array(skus).flat_map { |value| Products::ListingSkuResolver.aliases(value) }.uniq
      end
    end
  end
end
