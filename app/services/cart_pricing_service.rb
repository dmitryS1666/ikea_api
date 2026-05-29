class CartPricingService
  def self.order_as_cart(order)
    cart = Cart.new(user: order.user, promo_code: order.promo_code)
    order.order_items.each do |oi|
      ci = cart.cart_items.build(product_sku: oi.product_sku, quantity: oi.quantity)
      # Unpersisted cart_items do not get products via includes(); pricing would see zero PLN.
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

    # Получаем базовые данные для расчета (курс и буфер)
    pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
    eur_rate = ExchangeRate.fetch_or_create('EUR')&.rate_per_unit || 0
    buffer = PriceCalculationService.exchange_rate_buffer
    pln_rate_with_buffer = pln_rate * buffer

    items_goods_pln = 0.0
    discount_total_pln = 0.0
    discount_total_byn = 0.0
    total_weight = 0.0
    total_items_cost_eur = 0.0
    delivery_poland_byn = 0.0
    delivery_to_belarus_byn = 0.0

    # Pre-calculate promo applicability for all items at once
    promos = promo_valid ? [promo] : []
    cart_products = cart.cart_items.map(&:product).compact
    promo_applicability = get_promo_applicability(cart_products, promos)

    # includes() breaks product association for unpersisted cart_items (e.g. CartPricingService.order_as_cart).
    items_relation =
      if cart.cart_items.all?(&:persisted?)
        cart.cart_items.includes(product: :category_products)
      else
        cart.cart_items.each do |item|
          item.product ||= Product.includes(:category_products).find_by(sku: item.product_sku) if item.product_sku.present?
        end
        cart.cart_items
      end

    items = items_relation.map do |item|
      product_pln = item.product&.price.to_f || 0
      weight = item.product&.packaging_weight_kg.to_f
      quantity = item.quantity
      delivery_unit_pln = item.product&.delivery_cost.to_f
      line_weight = weight * quantity
      total_weight += line_weight

      line_breakdown = PriceCalculationService.line_breakdown_pln(
        unit_price_zl: product_pln,
        quantity: quantity,
        weight_kg: line_weight,
        delivery_unit_pln: delivery_unit_pln
      )
      line_byn = PriceCalculationService.line_byn_components(
        unit_price_zl: product_pln,
        quantity: quantity,
        weight_kg: line_weight,
        delivery_unit_pln: delivery_unit_pln,
        pln_rate: pln_rate,
        buffer: buffer
      )

      storefront_line_byn_before_discount = (line_byn[:goods_byn] + line_byn[:delivery_poland_byn]).round(2)
      full_line_byn_before_discount = line_byn[:total_byn]
      unit_price_byn_before_discount = quantity.positive? ? (storefront_line_byn_before_discount / quantity).round(2) : 0.0

      # Промо применяется к витринной цене позиции (без доставки в Беларусь).
      promo_applied = promo_valid && promo_applicability[item.product_sku]&.any?
      unit_discount_byn = promo_applied ? calculate_unit_discount_byn(promo, unit_price_byn_before_discount, pln_rate, buffer) : 0.0
      unit_discount_byn = [unit_discount_byn, unit_price_byn_before_discount].min.round(2)
      line_discount_byn = (unit_discount_byn * quantity).round(2)
      line_discount_pln = if pln_rate_with_buffer.positive?
                            (line_discount_byn / pln_rate_with_buffer).round(2)
                          else
                            0.0
                          end

      unit_discount_pln = quantity.positive? ? (line_discount_pln / quantity).round(2) : 0.0
      discount_total_pln += unit_discount_pln * quantity
      discount_total_byn += line_discount_byn

      line_total_byn = [storefront_line_byn_before_discount - line_discount_byn, 0.0].max.round(2)
      line_total_byn_checkout = [full_line_byn_before_discount - line_discount_byn, 0.0].max.round(2)
      line_total_pln = if pln_rate_with_buffer.positive?
                         (line_total_byn_checkout / pln_rate_with_buffer).round(2)
                       else
                         0.0
                       end
      unit_price_byn = quantity.positive? ? (line_total_byn / quantity).round(2) : 0.0
      unit_price_byn_checkout = quantity.positive? ? (line_total_byn_checkout / quantity).round(2) : 0.0

      items_goods_pln += line_breakdown[:goods_pln]
      delivery_poland_byn += line_byn[:delivery_poland_byn]
      delivery_to_belarus_byn += line_byn[:delivery_belarus_byn]

      markup_k = line_breakdown[:markup_k]

      # Расчет пошлины для отдельной позиции (line total) для информации
      item_cost_eur = (product_pln * pln_rate / eur_rate).round(2) if eur_rate.positive?
      line_cost_eur = (item_cost_eur || 0) * quantity
      total_items_cost_eur += line_cost_eur
      
      line_customs = (line_cost_eur.positive? && line_weight.positive?) ? CustomsDutyService.calculate(line_cost_eur, line_weight, eur_rate) : nil

      {
        sku: item.product_sku,
        quantity: quantity,
        unit_price_pln: product_pln,
        unit_price_byn: unit_price_byn,
        unit_price_byn_checkout: unit_price_byn_checkout,
        unit_price_byn_before_discount: unit_price_byn_before_discount,
        line_total_byn_checkout: line_total_byn_checkout,
        unit_discount_byn: unit_discount_byn,
        unit_discount_pln: unit_discount_pln,
        line_total_pln: line_total_pln.round(2),
        line_total_byn: line_total_byn,
        pricing_mode: line_breakdown[:mode].to_s,
        promo_applied: promo_applied,
        promo_code: promo_applied ? promo.code : nil,
        weight: weight,
        customs_duty_byn: line_customs ? line_customs[:duty_byn] : 0,
        customs_fee_byn: line_customs ? line_customs[:fee_byn] : 0,
        customs_total_byn: line_customs ? line_customs[:total_byn] : 0
      }
    end

    # Расчет пошлины для всей корзины
    cart_customs = CustomsDutyService.calculate(total_items_cost_eur, total_weight, eur_rate)

    # Итого в PLN и BYN: полная сумма строк (с доставкой в РБ) для checkout.
    total_pln = items.sum { |i| i[:line_total_pln].to_f }
    total_byn = items.sum { |i| i[:line_total_byn_checkout].to_f }.round(2)

    delivery_total_byn = (delivery_poland_byn + delivery_to_belarus_byn).round(2)

    # Для правил — только товары с наценкой (без доставки и WC_BY)
    items_total_byn = (items_goods_pln * pln_rate_with_buffer).round(2)
    rules = CartRulesService.call(subtotal_new_byn: items_total_byn)

    {
      items: items,
      totals: {
        subtotal_new_byn: items_total_byn, # Для совместимости с CheckoutService
        items_total_byn: items_total_byn,
        total_pln: total_pln.round(2),
        delivery_total_byn: delivery_total_byn,
        delivery_poland_byn: delivery_poland_byn,
        delivery_to_belarus_byn: delivery_to_belarus_byn,
        total_byn: total_byn,
        discount_total_byn: discount_total_byn.round(2),
        total_weight_kg: total_weight.to_f,
        customs_total_byn: cart_customs[:total_byn],
        customs_duty_byn: cart_customs[:duty_byn],
        customs_fee_byn: cart_customs[:fee_byn]
      },
      promo: {
        code: promo&.code,
        valid: promo_valid
      },
      meta: {
        min_order_amount: rules[:rules][:min_order_amount_byn],
        can_checkout: rules[:flags][:checkout_allowed],
        min_order_error: rules[:flags][:checkout_allowed] ? nil : "Оформление доступно от #{rules[:rules][:min_order_amount_byn]} руб.",
        free_delivery_threshold: rules[:rules][:free_delivery_threshold_byn],
        free_delivery_remaining: rules[:flags][:free_delivery_missing_byn]
      }
    }
  end

  def self.calculate_unit_discount_byn(promo, unit_price_byn, pln_rate = nil, buffer = nil)
    return 0 unless promo && unit_price_byn.to_f.positive?

    case promo.discount_type
    when 'percent'
      (unit_price_byn.to_f * promo.discount_value / 100.0).round(2)
    when 'fixed_pln'
      pln_rate ||= ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 1
      buffer ||= PriceCalculationService.exchange_rate_buffer
      [promo.discount_value.to_f * pln_rate * buffer, unit_price_byn.to_f].min.round(2)
    when 'fixed_byn'
      [promo.discount_value.to_f, unit_price_byn.to_f].min.round(2)
    else
      0
    end
  end

  # Change to public for use in CartAutoPromoService
  def self.get_promo_applicability(products, promos)
    return {} if Array(products).empty? || Array(promos).empty?

    sku_to_cat_ids = {}
    Array(products).each do |p|
      cat_ids = ([p.category_id] + p.category_products.map(&:category_id)).compact.uniq
      sku_to_cat_ids[p.sku] = cat_ids
    end

    # Pre-fetch promo relationships
    promos.each { |p| p.promo_code_products.to_a; p.promo_code_categories.to_a }

    applicability = {}
    Array(products).each do |p|
      cat_ids = sku_to_cat_ids[p.sku]
      applicability[p.sku] = promos.select { |promo| promo.applies_to_sku?(p.sku, cat_ids) }
    end
    applicability
  end
end
