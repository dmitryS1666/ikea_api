module Api
  module V1
    module Account
      class PickupPointsController < ApplicationController
        before_action :authenticate_user
        before_action :set_user_pickup_point, only: [:destroy]

        def index
          points = current_user.user_pickup_points.alive.order(created_at: :desc)
          render json: UserPickupPointSerializer.new(points).serializable_hash
        end

        def create
          attrs = pickup_point_params
          point = current_user.user_pickup_points.alive.find_by(
            provider: attrs[:provider],
            external_id: attrs[:external_id]
          )

          if point
            point.update!(attrs.except(:provider, :external_id))
            render json: UserPickupPointSerializer.new(point).serializable_hash, status: :ok
            return
          end

          point = current_user.user_pickup_points.new(attrs)
          if point.save
            render json: UserPickupPointSerializer.new(point).serializable_hash, status: :created
          else
            render json: { errors: point.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @user_pickup_point.update!(deleted_at: Time.current)
          head :no_content
        end

        private

        def set_user_pickup_point
          @user_pickup_point = current_user.user_pickup_points.alive.find_by(id: params[:id])
          return if @user_pickup_point

          render json: { error: "ПВЗ не найден" }, status: :not_found
        end

        def pickup_point_params
          params.permit(
            :pickup_point_id, :provider, :external_id, :city, :address,
            :working_hours, :lat, :lng, raw_payload: {}
          )
        end
      end
    end
  end
end
