class CartSelectionService
  ItemSelection = Struct.new(:sku, :quantity, keyword_init: true)

  def self.items_param_present?(params)
    parse_items_param(params).present?
  end

  def self.parse_items_param(params)
    raw = params[:items]
    return nil if raw.blank?

    if raw.is_a?(String)
      begin
        raw = JSON.parse(raw)
      rescue JSON::ParserError
        return nil
      end
    end

    list =
      case raw
      when Array then raw
      when ActionController::Parameters then raw.to_unsafe_a
      when Hash then raw.values
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

    subset = Cart.new(user: cart.user, promo_code: cart.promo_code)
    resolved = []

    selections.each do |sel|
      cart_item = find_cart_item_by_public_sku(cart, sel.sku)
      unless cart_item
        return { error: "Товар #{sel.sku} отсутствует в корзине", code: 'item_not_in_cart', sku: sel.sku }
      end

      qty = [sel.quantity, cart_item.quantity.to_i].min
      if qty <= 0
        return { error: "Некорректное количество для #{sel.sku}", code: 'invalid_quantity', sku: sel.sku }
      end

      subset.cart_items.build(product_sku: cart_item.product_sku, quantity: qty)
      resolved << ItemSelection.new(sku: cart_item.product_sku, quantity: qty)
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
    return { error: 'Корзина пуста', code: 'cart_empty' } if selections.blank?

    build_subset_cart(cart: cart, selections: selections)
  end

  def self.items_key_present?(params)
    params.key?(:items) || params.key?('items')
  end

  def self.consume_from_cart!(cart:, selections:)
    return if selections.blank?

    selections.each do |sel|
      cart_item = find_cart_item_by_public_sku(cart, sel.sku)
      next unless cart_item

      remaining = cart_item.quantity.to_i - sel.quantity.to_i
      if remaining <= 0
        cart_item.destroy!
      else
        cart_item.update!(quantity: remaining)
      end
    end
  end

  def self.selections_from_order(order)
    order.order_items.map do |oi|
      ItemSelection.new(sku: oi.product_sku, quantity: oi.quantity.to_i)
    end
  end

  def self.normalize_selections(cart:, selections:)
    return selections_from_cart(cart) if selections.blank?

    selections
  end

  def self.selections_from_cart(cart)
    cart.cart_items.map do |ci|
      ItemSelection.new(sku: ci.product_sku, quantity: ci.quantity.to_i)
    end
  end

  def self.find_cart_item_by_public_sku(cart, sku)
    cart.cart_items.find { |item| sku_aliases(sku).include?(item.product_sku.to_s) }
  end

  def self.sku_aliases(sku)
    Products::ListingSkuResolver.aliases(sku)
  end

  def self.selections_equal?(left, right)
    normalize_key = lambda do |list|
      Array(list).map { |s| [s.sku.to_s, s.quantity.to_i] }.sort
    end
    normalize_key.call(left) == normalize_key.call(right)
  end

  def self.validate_against_order!(order:, params:)
    selections = parse_items_param(params)
    return { ok: true } if selections.nil?

    order_qty = order.order_items.group_by(&:product_sku).transform_values { |rows| rows.sum(&:quantity) }

    selections.each do |sel|
      matched_sku = sku_aliases(sel.sku).find { |alias_sku| order_qty.key?(alias_sku) }
      expected = order_qty[matched_sku]
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
