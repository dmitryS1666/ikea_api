class CartSummaryService
  def self.call(cart:, items: nil, promo_code: nil)
    effective =
      if items.present?
        built = CartSelectionService.build_subset_cart(cart: cart, selections: items)
        return built if built[:error]

        built[:cart]
      else
        cart
      end

    return { error: 'Корзина пуста', code: 'cart_empty' } if effective.cart_items.blank?

    promo_result = apply_calculation_promo(effective, promo_code)
    return promo_result if promo_result[:error]

    pricing = CartPricingService.call(cart: effective)
    totals = CartDisplayTotalsService.for_summary(pricing[:totals])
    delivery_options = DeliveryOptionsService.call(effective)
    rules = CartRulesService.call(subtotal_new_byn: totals[:subtotal_new_byn])

    pricing_items = pricing[:items].index_by { |entry| entry[:sku] }

    {
      items: format_items(effective.cart_items, pricing_items),
      items_count: effective.cart_items.sum(&:quantity),
      subtotal_new_byn: format_byn(totals[:subtotal_new_byn]),
      discount_total_byn: format_byn(totals[:discount_total_byn]),
      customs_total_byn: format_byn(totals[:customs_total_byn]),
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn]),
      total_weight_kg: totals[:total_weight_kg].to_f,
      total_byn: format_byn(totals[:total_byn]),
      final_total_byn: format_byn(totals[:final_total_byn]),
      delivery: format_delivery(totals, delivery_options),
      meta: {
        min_order_amount_byn: format_byn(rules[:rules][:min_order_amount_byn]),
        checkout_allowed: rules[:flags][:checkout_allowed],
        min_order_error: rules[:flags][:checkout_allowed] ? nil : "Оформление доступно от #{rules[:rules][:min_order_amount_byn]} руб."
      }
    }
  end

  def self.apply_calculation_promo(cart, promo_code)
    return {} if promo_code.blank?

    promo = PromoCode.find_by(code: promo_code.to_s.strip.upcase)
    return { error: 'invalid_promo_code', code: 'invalid_promo_code' } unless promo&.active_now?

    # Calculation-only promo: virtual/subset cart is not persisted, so this does
    # not mutate the real user/guest cart.
    cart.promo_code = promo
    {}
  end

  def self.format_delivery(totals, delivery_options)
    methods = Array(delivery_options[:methods]).map do |method|
      {
        code: method[:code],
        available: method[:available],
        reason: method[:reason]
      }
    end

    {
      available_methods: methods,
      europost_eligible: delivery_options.dig(:cart_vgh, :eligible_for_europost) == true,
      ineligible_reason: delivery_options.dig(:cart_vgh, :ineligible_reason),
      total_weight_kg: totals[:total_weight_kg].to_f,
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn])
    }
  end

  def self.format_items(cart_items, pricing_items)
    cart_items.map do |item|
      line = pricing_items[item.product_sku] || {}
      format_item(item.product_sku, item.quantity, line)
    end
  end

  def self.format_item(sku, quantity, line)
    qty = quantity.to_i
    unit_before = line[:unit_price_byn_before_discount]
    unit_after = line[:unit_price_byn]

    {
      sku: sku,
      quantity: qty,
      pricing: {
        unit_price_old_byn: format_byn(unit_before),
        unit_price_new_byn: format_byn(unit_after),
        unit_discount_byn: format_byn(line[:unit_discount_byn]),
        line_total_old_byn: format_byn(unit_before.to_f * qty),
        line_total_new_byn: format_byn(line[:line_total_byn]),
        line_discount_byn: format_byn(line[:line_discount_byn]),
        pricing_mode: line[:pricing_mode],
        promo_applied: line[:promo_applied] || false,
        promo_code: line[:promo_code]
      }
    }
  end

  def self.format_byn(value)
    format('%.2f', value.to_f)
  end
end
