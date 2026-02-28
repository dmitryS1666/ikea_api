module FavoriteHelper
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user_optional
  end

  private

  def current_favorite_skus
    favorite, _, _ = FavoriteTokenResolver.call(request: request, params: params, user: current_user)
    favorite.favorite_items.pluck(:product_sku)
  end
end
