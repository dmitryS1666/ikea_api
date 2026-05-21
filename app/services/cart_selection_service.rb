class CartSelectionService
  ItemSelection = Struct.new(:sku, :quantity, keyword_init: true)

  def self.items_param_present?(params)
    parse_items_param(params).present?
  end

  def self.parse_items_param(params)
    raw = params[:items]
    return nil if raw.blank?

    list =
      case raw
      when Array then raw
      when ActionController::Parameters then raw.to_unsafe_a
      else
        []
      end

    list.filter_map do |entry|
      h = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
      next unless h.is_a?(Hash)

      sku = (h['sku'] || h[:sku]).to_s.strip
      quantity = (h['quantity'] || h[:quantity]).to_i
      next if sku.blank? || quantity <= 0

      ItemSelection.new(sku: sku, quantity: quantity)
    end.presence
  end

  # Builds an unpersisted cart containing only the requested lines (capped by cart stock).
  def self.build_subset_cart(cart:, selections:)
    return { error: 'Не указаны товары для оформления', code: 'items_required' } if selections.blank?

    cart_items_by_sku = cart.cart_items.index_by(&:product_sku)
    subset = Cart.new(user: cart.user, promo_code: cart.promo_code)
    resolved = []

    selections.each do |sel|
      cart_item = cart_items_by_sku[sel.sku]
      unless cart_item
        return { error: "Товар #{sel.sku} отсутствует в корзине", code: 'item_not_in_cart', sku: sel.sku }
      end

      qty = [sel.quantity, cart_item.quantity.to_i].min
      if qty <= 0
        return { error: "Некорректное количество для #{sel.sku}", code: 'invalid_quantity', sku: sel.sku }
      end

      subset.cart_items.build(product_sku: sel.sku, quantity: qty)
      resolved << ItemSelection.new(sku: sel.sku, quantity: qty)
    end

    if subset.cart_items.blank?
      return { error: 'Не указаны товары для оформления', code: 'items_required' }
    end

    subset.cart_items.each do |item|
      item.product = Product.includes(:category_products).find_by(sku: item.product_sku)
    end

    { cart: subset, selections: resolved }
  end

  def self.apply(cart:, params:)
    return { cart: cart, selections: nil } unless items_key_present?(params)

    selections = parse_items_param(params)
    return { error: 'Укажите товары для оформления', code: 'items_required' } if selections.blank?

    build_subset_cart(cart: cart, selections: selections)
  end

  def self.items_key_present?(params)
    params.key?(:items) || params.key?('items')
  end

  def self.consume_from_cart!(cart:, selections:)
    return if selections.blank?

    selections.each do |sel|
      cart_item = cart.cart_items.find_by(product_sku: sel.sku)
      next unless cart_item

      remaining = cart_item.quantity.to_i - sel.quantity.to_i
      if remaining <= 0
        cart_item.destroy!
      else
        cart_item.update!(quantity: remaining)
      end
    end
  end

  def self.validate_against_order!(order:, params:)
    selections = parse_items_param(params)
    return { ok: true } if selections.nil?

    order_qty = order.order_items.group_by(&:product_sku).transform_values { |rows| rows.sum(&:quantity) }

    selections.each do |sel|
      expected = order_qty[sel.sku]
      unless expected
        return { error: "Товар #{sel.sku} отсутствует в черновике заказа", code: 'item_not_in_draft', sku: sel.sku }
      end
      if sel.quantity != expected
        return {
          error: "Количество #{sel.sku} не совпадает с черновиком заказа",
          code: 'items_mismatch',
          sku: sel.sku
        }
      end
    end

    if selections.size != order_qty.size
      return { error: 'Список товаров не совпадает с черновиком заказа', code: 'items_mismatch' }
    end

    { ok: true }
  end
end
