class CartTokenResolver
  def self.call(request:, params:, user: nil)
    token = request.headers['X-Cart-Token'].presence || params[:cart_token].presence

    # Explicit cart_token must win even for authenticated users.
    # Frontend keeps the guest cart token during login/checkout continuation and
    # can still submit it right after phone auth.
    if token.present?
      cart = Cart.find_by(guest_token: token)
      return [cart, cart.guest_token, false] if cart.present? && !cart.expired?
    end

    if user
      cart = user.cart || user.create_cart!(expires_at: 1.year.from_now, guest_token: SecureRandom.hex(24))
      return [cart, cart.guest_token, false]
    end

    return new_cart_response if token.blank?

    new_cart_response
  end

  def self.new_cart_response
    cart = Cart.create!
    [cart, cart.guest_token, true]
  end
  private_class_method :new_cart_response
end
