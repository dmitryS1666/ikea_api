module Api
  module V1
    class AuthController < ApplicationController
      def login
        # Для обычных пользователей вход теперь только по номеру телефона
        # Для админов и менеджеров оставляем вход по паролю
        user = User.find_by(username: params[:username]) || User.find_by(email: params[:username]) || User.find_by(phone: params[:username].to_s.gsub(/\D/, ''))
        
        if user && (user.admin? || user.manager?)
          if user.authenticate(params[:password]) && user.is_active?
            return render_login_success(user)
          else
            return render json: { error: 'Неверные учетные данные' }, status: :unauthorized
          end
        end

        render json: { error: 'Для входа используйте подтверждение по номеру телефона' }, status: :forbidden
      end

      def register
        # Регистрация теперь происходит через verify_phone_code
        render json: { error: 'Используйте подтверждение по телефону для регистрации' }, status: :method_not_allowed
      end
      
      def send_phone_code
        result = PhoneAuthService.send_code(
          phone: params[:phone],
          metadata: {
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            context: 'auth'
          }
        )

        if result[:success]
          render json: { message: result[:message] }
        else
          render json: { error: result[:error] }, status: :unprocessable_entity
        end
      end

      def check_phone
        phone = normalized_phone(params[:phone])

        if phone.blank? || phone.length < 10
          return render json: { error: 'Неверный формат телефона' }, status: :unprocessable_entity
        end

        render json: {
          phone: phone,
          exists: User.exists?(phone: phone)
        }
      end

      def verify_phone_code
        result = PhoneAuthService.verify_code(
          phone: params[:phone], 
          code: params[:code],
          username: params[:username],
          email: params[:email]
        )
        
        if result[:success]
          user = result[:user]
          
          # Если пользователь уже существовал, но передано новое имя, обновляем его
          if !result[:is_new] && params[:username].present?
            user.update(username: params[:username])
          end
          
          # Merge guest cart if present
          guest_token = request.headers['X-Cart-Token'].presence || params[:cart_token].presence
          cart = if guest_token
                   CartMergeService.call(guest_token: guest_token, user: user)
                 else
                   user.cart || user.create_cart!
                 end

          # Update last login in CRM
          CrmIntegrationService.update_last_login(user)
          
          token = JwtService.encode({ user_id: user.id })
          
          status = result[:is_new] ? :created : :ok
          
          render json: {
            token: token,
            cart_token: cart.guest_token,
            user: {
              id: user.id,
              username: user.username,
              role: user.role,
              phone: user.phone,
              email: user.email
            },
            is_new: result[:is_new]
          }, status: status
        else
          render json: { error: result[:error] }, status: :unauthorized
        end
      end

      private

      def render_login_success(user)
        # Merge guest cart if present
        guest_token = request.headers['X-Cart-Token'].presence || params[:cart_token].presence
        cart = if guest_token
                 CartMergeService.call(guest_token: guest_token, user: user)
               else
                 user.cart || user.create_cart!
               end

        token = JwtService.encode({ user_id: user.id })
        render json: {
          token: token,
          cart_token: cart.guest_token,
          user: {
            id: user.id,
            username: user.username,
            role: user.role,
            phone: user.phone
          }
        }
      end
      
      def user_params
        params.require(:user).permit(:username, :email, :password, :password_confirmation)
      end

      def normalized_phone(value)
        value.to_s.gsub(/\D/, '')
      end
    end
  end
end
