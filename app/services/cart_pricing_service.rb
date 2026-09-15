class CartPricingService
  def self.order_as_cart(order)
    cart = Cart.new(user: order.user, promo_code: order.promo_code)
    order.order_items.each do |oi|
      ci = cart.cart_items.build(product_sku: oi.product_sku, quantity: oi.quantity)
      ci.product = Product.includes(:category_products).find_by(sku: oi.product_sku)
    end
    cart
  end

  def self.call_from_order(order:)
    call(cart: order_as_cart(order))
  end

  def self.call(cart:)
    promo = cart.promo_code
    promo_valid = promo&.active_now?

    pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
    eur_rate = ExchangeRate.fetch_or_create("EUR")&.rate_per_unit
    buffer = PriceCalculationService.exchange_rate_buffer
    pln_rate_with_buffer = (Pricing::Money.bd(pln_rate) || BigDecimal("0")) * Pricing::Money.bd(buffer)

    discount_total_pln = 0.0
    discount_total_byn = 0.0
    cart_ikea_pln = BigDecimal("0")
    cart_weight_kg = BigDecimal("0")
    delivery_poland_byn = 0.0
    delivery_to_belarus_byn = 0.0
    pricing_blocked = false
    pricing_block_skus = []

    promos = promo_valid ? [promo] : []
    cart_products = cart.cart_items.map(&:product).compact
    promo_applicability = get_promo_applicability(cart_products, promos)

    items_relation =
      if cart.cart_items.all?(&:persisted?)
        cart.cart_items.includes(product: :category_products)
      else
        cart.cart_items.each do |item|
          item.product ||= Product.includes(:category_products).find_by(sku: item.product_sku) if item.product_sku.present?
        end
        cart.cart_items
      end

    parcel_result = Delivery::ParcelPackingService.call(cart)

    items = items_relation.map do |item|
      product = item.product
      quantity = item.quantity.to_i
      unit = PriceCalculationService.for_product(product, pln_rate: pln_rate, eur_rate: eur_rate, buffer: buffer)

      unless unit[:pricing_available]
        pricing_blocked = true
        pricing_block_skus << item.product_sku
        next unavailable_item(item, unit, quantity)
      end

      ikea_unit = Pricing::Money.bd(product.price)
      weight_unit = unit[:weight_kg]
      cart_ikea_pln += ikea_unit * quantity
      cart_weight_kg += weight_unit * quantity

      base_unit_byn = Pricing::Money.to_f_round2(unit[:base_price_byn])
      goods_line_byn = Pricing::Money.to_f_round2(unit[:goods_pln] * quantity * unit[:pln_byn_raw] * unit[:exchange_rate_buffer])
      delivery_poland_line = Pricing::Money.to_f_round2(unit[:d_ikea_pln] * quantity * unit[:pln_byn_raw] * unit[:exchange_rate_buffer])
      delivery_belarus_line = Pricing::Money.to_f_round2(unit[:wc_pln] * quantity * unit[:pln_byn_raw] * unit[:exchange_rate_buffer])
      base_line_byn = (base_unit_byn * quantity).round(2)

      promo_applied = promo_valid && promo_applicability[item.product_sku]&.any?
      unit_discount_byn = promo_applied ? calculate_unit_discount_byn(promo, base_unit_byn, pln_rate, buffer) : 0.0
      unit_discount_byn = [unit_discount_byn, base_unit_byn].min.round(2)
      line_discount_byn = (unit_discount_byn * quantity).round(2)
      line_discount_pln = if pln_rate_with_buffer.positive?
                            (line_discount_byn / pln_rate_with_buffer).round(2)
                          else
                            0.0
                          end
      unit_discount_pln = quantity.positive? ? (line_discount_pln / quantity).round(2) : 0.0
      discount_total_pln += line_discount_pln
      discount_total_byn += line_discount_byn

      line_total_byn = [base_line_byn - line_discount_byn, 0.0].max.round(2)
      unit_price_byn = quantity.positive? ? (line_total_byn / quantity).round(2) : 0.0
      line_total_byn = (unit_price_byn * quantity).round(2)
      line_total_pln = if pln_rate_with_buffer.positive?
                         (line_total_byn / pln_rate_with_buffer).round(2)
                       else
                         0.0
                       end

      delivery_poland_byn += delivery_poland_line
      delivery_to_belarus_byn += delivery_belarus_line

      {
        sku: item.product_sku,
        quantity: quantity,
        unit_price_pln: product.price.to_f,
        unit_price_byn: unit_price_byn,
        unit_price_byn_checkout: unit_price_byn,
        unit_price_byn_before_discount: base_unit_byn,
        line_total_byn_checkout: line_total_byn,
        unit_discount_byn: unit_discount_byn,
        unit_discount_pln: unit_discount_pln,
        line_discount_byn: line_discount_byn,
        line_total_pln: line_total_pln,
        line_total_byn: line_total_byn,
        pricing_mode: unit[:pricing_mode].to_s,
        promo_applied: promo_applied,
        promo_code: promo_applied ? promo.code : nil,
        weight: weight_unit.to_f,
        customs_duty_byn: 0.0,
        customs_fee_byn: 0.0,
        customs_total_byn: 0.0,
        pricing_available: true,
        pricing_status: "ok",
        pricing_errors: [],
        goods_byn: goods_line_byn,
        delivery_poland_byn: delivery_poland_line,
        delivery_belarus_byn: delivery_belarus_line
      }
    end

    vat = Pricing::Settings.vat_multiplier
    cart_customs_cost_eur = if eur_rate.to_f.positive?
                              (cart_ikea_pln / vat) * (Pricing::Money.bd(pln_rate) / Pricing::Money.bd(eur_rate))
                            else
                              BigDecimal("0")
                            end
    cart_customs = CustomsDutyService.calculate(cart_customs_cost_eur, cart_weight_kg, eur_rate)

    items_total_byn = items.sum { |row| row[:unit_price_byn_before_discount].to_f * row[:quantity].to_i }.round(2)
    total_pln = items.sum { |row| row[:line_total_pln].to_f }.round(2)

    totals = CartDisplayTotalsService.for_summary(
      items_total_byn: items_total_byn,
      subtotal_new_byn: items_total_byn,
      discount_total_byn: discount_total_byn.round(2),
      delivery_to_belarus_byn: delivery_to_belarus_byn.round(2),
      delivery_poland_byn: delivery_poland_byn.round(2),
      local_delivery_total_byn: 0.0,
      total_pln: total_pln,
      total_weight_kg: cart_weight_kg.to_f,
      customs_total_byn: cart_customs[:total_byn],
      customs_duty_byn: cart_customs[:duty_byn],
      customs_fee_byn: cart_customs[:fee_byn]
    )
    rules = CartRulesService.call(subtotal_new_byn: totals[:items_total_byn])
    checkout_allowed = rules[:flags][:checkout_allowed] && !pricing_blocked
    min_order_error =
      if pricing_blocked
        skus = pricing_block_skus.uniq.join(", ")
        "Цена уточняется для товаров: #{skus}. Оформление недоступно, пока не заданы вес и D_IKEA."
      elsif checkout_allowed
        nil
      else
        "Оформление доступно от #{rules[:rules][:min_order_amount_byn]} руб."
      end

    {
      items: items,
      totals: totals,
      promo: {
        code: promo&.code,
        valid: promo_valid
      },
      meta: {
        min_order_amount: rules[:rules][:min_order_amount_byn],
        can_checkout: checkout_allowed,
        min_order_error: min_order_error,
        free_delivery_threshold: rules[:rules][:free_delivery_threshold_byn],
        free_delivery_remaining: rules[:flags][:free_delivery_missing_byn],
        pricing_blocked: pricing_blocked,
        pricing_block_skus: pricing_block_skus.uniq,
        parcel_total_weight_kg: parcel_result[:total_weight_kg].to_f
      }
    }
  rescue Pricing::ConfigurationError => e
    Rails.logger.error("[CartPricingService] #{e.message}")
    {
      items: [],
      totals: CartDisplayTotalsService.for_summary({}),
      promo: { code: promo&.code, valid: promo_valid },
      meta: {
        min_order_amount: CartRulesService::DEFAULTS[:min_order_amount_byn],
        can_checkout: false,
        min_order_error: "Некорректная конфигурация ценообразования. Оформление недоступно.",
        free_delivery_threshold: 0.0,
        free_delivery_remaining: 0.0,
        pricing_blocked: true,
        pricing_block_skus: []
      }
    }
  end

  def self.calculate_unit_discount_byn(promo, unit_price_byn, pln_rate = nil, buffer = nil)
    return 0 unless promo && unit_price_byn.to_f.positive?

    case promo.discount_type
    when "percent"
      (unit_price_byn.to_f * promo.discount_value / 100.0).round(2)
    when "fixed_pln"
      pln_rate ||= ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 1
      buffer ||= PriceCalculationService.exchange_rate_buffer
      [promo.discount_value.to_f * pln_rate.to_f * buffer.to_f, unit_price_byn.to_f].min.round(2)
    when "fixed_byn"
      [promo.discount_value.to_f, unit_price_byn.to_f].min.round(2)
    else
      0
    end
  end

  def self.get_promo_applicability(products, promos)
    return {} if Array(products).empty? || Array(promos).empty?

    sku_to_cat_ids = {}
    Array(products).each do |p|
      cat_ids = ([p.category_id] + p.category_products.map(&:category_id)).compact.uniq
      sku_to_cat_ids[p.sku] = cat_ids
    end

    promos.each { |p| p.promo_code_products.to_a; p.promo_code_categories.to_a }

    applicability = {}
    Array(products).each do |p|
      cat_ids = sku_to_cat_ids[p.sku]
      applicability[p.sku] = promos.select { |promo| promo.applies_to_sku?(p.sku, cat_ids) }
    end
    applicability
  end

  def self.unavailable_item(item, unit, quantity)
    {
      sku: item.product_sku,
      quantity: quantity,
      unit_price_pln: item.product&.price.to_f,
      unit_price_byn: 0.0,
      unit_price_byn_checkout: 0.0,
      unit_price_byn_before_discount: 0.0,
      line_total_byn_checkout: 0.0,
      unit_discount_byn: 0.0,
      unit_discount_pln: 0.0,
      line_discount_byn: 0.0,
      line_total_pln: 0.0,
      line_total_byn: 0.0,
      pricing_mode: nil,
      promo_applied: false,
      promo_code: nil,
      weight: nil,
      customs_duty_byn: 0.0,
      customs_fee_byn: 0.0,
      customs_total_byn: 0.0,
      pricing_available: false,
      pricing_status: unit[:pricing_status] || "requires_clarification",
      pricing_errors: Array(unit[:pricing_errors])
    }
  end
  private_class_method :unavailable_item
end
