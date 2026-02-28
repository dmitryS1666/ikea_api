class FavoriteTokenResolver
  def self.call(request:, params:, user: nil)
    # 1. Если есть пользователь, возвращаем его список избранного
    if user
      favorite = user.favorite || user.create_favorite!(expires_at: 1.year.from_now, guest_token: SecureRandom.hex(24))
      return [favorite, favorite.guest_token, false]
    end

    # 2. Иначе работаем с гостевыми токенами
    token = request.headers['X-Favorite-Token'].presence || params[:favorite_token].presence
    return new_favorite_response if token.blank?

    favorite = Favorite.find_by(guest_token: token)
    return new_favorite_response if favorite.nil? || favorite.expired?

    [favorite, token, false]
  end

  def self.new_favorite_response
    favorite = Favorite.create!
    [favorite, favorite.guest_token, true]
  end
  private_class_method :new_favorite_response
end
