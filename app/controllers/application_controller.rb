class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods
  
  def authenticate_user
    token = request.headers['Authorization']&.split(' ')&.last
    
    if token
      decoded = JwtService.decode(token)
      @current_user = User.find(decoded[:user_id]) if decoded
    end
    
    render json: { error: 'Не авторизован' }, status: :unauthorized unless @current_user
  end
  
  def current_user
    @current_user
  end
end
