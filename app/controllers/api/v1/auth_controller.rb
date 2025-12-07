module Api
  module V1
    class AuthController < ApplicationController
      def login
        user = User.find_by(username: params[:username])
        
        if user&.authenticate(params[:password]) && user.is_active?
          token = JwtService.encode({ user_id: user.id })
          render json: {
            token: token,
            user: {
              id: user.id,
              username: user.username,
              role: user.role
            }
          }
        else
          render json: { error: 'Неверные учетные данные' }, status: :unauthorized
        end
      end
      
      def register
        user = User.new(user_params)
        
        if user.save
          token = JwtService.encode({ user_id: user.id })
          render json: {
            token: token,
            user: {
              id: user.id,
              username: user.username,
              role: user.role
            }
          }, status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      private
      
      def user_params
        params.require(:user).permit(:username, :email, :password, :password_confirmation)
      end
    end
  end
end

