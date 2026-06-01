module Api
  module V1
    module Account
      class DeliveryAddressesController < ApplicationController
        include ApiValidationErrors

        before_action :authenticate_user
        before_action :set_delivery_address, only: [:update, :destroy]

        def index
          addresses = current_user.user_delivery_addresses.alive.order(created_at: :desc)
          render json: UserDeliveryAddressSerializer.new(addresses).serializable_hash
        end

        def create
          address = current_user.user_delivery_addresses.new(delivery_address_params)

          if address.save
            render json: UserDeliveryAddressSerializer.new(address).serializable_hash, status: :created
          else
            render_validation_errors(address, summary: "Не удалось сохранить адрес доставки")
          end
        end

        def update
          if @delivery_address.update(delivery_address_params)
            render json: UserDeliveryAddressSerializer.new(@delivery_address).serializable_hash
          else
            render_validation_errors(@delivery_address, summary: "Не удалось обновить адрес доставки")
          end
        end

        def destroy
          @delivery_address.update!(deleted_at: Time.current)
          head :no_content
        end

        private

        def set_delivery_address
          @delivery_address = current_user.user_delivery_addresses.alive.find_by(id: params[:id])
          return if @delivery_address

          render json: { error: "Адрес не найден" }, status: :not_found
        end

        def delivery_address_params
          params.permit(
            :city, :street, :house, :building, :apartment, :entrance, :floor,
            :has_elevator, :intercom, :is_private_house, :lat, :lng, :comment
          )
        end
      end
    end
  end
end
