class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods
  
  before_action :set_noindex_header

  def authenticate_user
    token = request.headers['Authorization']&.split(' ')&.last
    
    if token
      decoded = JwtService.decode(token)
      @current_user = User.find(decoded[:user_id]) if decoded
    end
    
    render json: { error: 'Не авторизован' }, status: :unauthorized unless @current_user
  end

  def authenticate_user_optional
    token = request.headers['Authorization']&.split(' ')&.last
    return unless token
    
    decoded = JwtService.decode(token)
    @current_user = User.find_by(id: decoded[:user_id]) if decoded
  rescue => _e
    # Token invalid or expired, just ignore for optional auth
    nil
  end
  
  def current_city
    request.headers['X-User-City'] || params[:city] || 'minsk'
  end

  def current_city_in
    Seo::CityMapper.call(current_city)
  end

  def current_user
    @current_user
  end

  def get_promo_applicability(products, promos)
    return {} if Array(products).empty? || Array(promos).empty?

    sku_to_cat_ids = {}
    Array(products).each do |p|
      cat_ids = ([p.category_id] + p.category_products.map(&:category_id)).compact.uniq
      sku_to_cat_ids[p.sku] = cat_ids
    end

    # Pre-fetch promo relationships to avoid N+1 inside applies_to_sku?
    promos.each { |p| p.promo_code_products.to_a; p.promo_code_categories.to_a }

    applicability = {}
    Array(products).each do |p|
      cat_ids = sku_to_cat_ids[p.sku]
      applicability[p.sku] = promos.select { |promo| promo.applies_to_sku?(p.sku, cat_ids) }
    end
    applicability
  end

  private

  def set_noindex_header
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
  end
end
