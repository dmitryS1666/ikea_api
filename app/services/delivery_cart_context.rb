# Resolves cart-like object for delivery VGH/pricing.
# Priority: order_id (draft) > items (+ optional cart_token subset) > cart_token (full cart).
class DeliveryCartContext
  class Error < StandardError
    attr_reader :code, :http_status

    def initialize(message, code:, http_status: :unprocessable_entity)
      super(message)
      @code = code
      @http_status = http_status
    end

    def as_json
      { error: message, code: code }
    end
  end

  def self.resolve(params:, request:, user: nil)
    new(params: params, request: request, user: user).resolve
  end

  def initialize(params:, request:, user: nil)
    @params = params
    @request = request
    @user = user
  end

  def resolve
    if @params[:order_id].present?
      return resolve_from_order_id
    end

    items = CartSelectionService.parse_items_param(@params)
    token = cart_token

    if items.present?
      if token.present?
        cart, = CartTokenResolver.call(request: @request, params: { cart_token: token })
        built = CartSelectionService.build_subset_cart(cart: cart, selections: items)
        raise Error.new(built[:error], code: built[:code] || "invalid_items") if built[:error]

        return built[:cart]
      end

      return cart_from_items(items)
    end

    if token.present?
      cart, = CartTokenResolver.call(request: @request, params: { cart_token: token })
      return cart
    end

    nil
  end

  def self.context_required?(params)
    params[:order_id].present? ||
      params[:cart_token].present? ||
      CartSelectionService.parse_items_param(params).present?
  end

  private

  def cart_token
    @request.headers["X-Cart-Token"].presence || @params[:cart_token].presence
  end

  def resolve_from_order_id
    order = Order.find_by(id: @params[:order_id])
    unless order&.checkout_draft?
      raise Error.new("Черновик заказа не найден", code: "draft_not_found", http_status: :not_found)
    end

    if @user && order.user_id != @user.id
      raise Error.new("Черновик заказа не найден", code: "draft_not_found", http_status: :not_found)
    end

    CartPricingService.order_as_cart(order)
  end

  def cart_from_items(items)
    skus = items.map(&:sku)
    products = Product.where(sku: skus).index_by(&:sku)
    virtual_item = Struct.new(:product, :quantity)
    virtual_items = items.filter_map do |sel|
      product = products[sel.sku]
      next if product.nil? || sel.quantity <= 0

      virtual_item.new(product, sel.quantity)
    end

    Struct.new(:cart_items).new(virtual_items)
  end
end
