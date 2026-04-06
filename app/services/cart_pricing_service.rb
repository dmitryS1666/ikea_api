class CartPricingService
  def self.call(cart:)
    promo = cart.promo_code
    promo_valid = promo&.active_now?

    # Получаем базовые данные для расчета (курс и буфер)
    pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
    eur_rate = ExchangeRate.fetch_or_create('EUR')&.rate_per_unit || 0
    buffer = PriceCalculationService.exchange_rate_buffer
    pln_rate_with_buffer = pln_rate * buffer

    items_total_pln = 0.0
    discount_total_pln = 0.0
    total_weight = 0.0
    total_items_cost_eur = 0.0

    # Pre-calculate promo applicability for all items at once
    promos = promo_valid ? [promo] : []
    cart_products = cart.cart_items.map(&:product).compact
    promo_applicability = get_promo_applicability(cart_products, promos)

    items = cart.cart_items.includes(product: :category_products).map do |item|
      product_pln = item.product&.price || 0
      weight = item.product&.weight || 0
      quantity = item.quantity
      total_weight += weight * quantity

      # Расчет наценки K для конкретного товара
      markup_k = PriceCalculationService.compute_k(product_pln)
      
      # Используем предосчитанную применимость промокода
      promo_applied = promo_valid && promo_applicability[item.product_sku]&.any?
      unit_discount_pln = promo_applied ? calculate_unit_discount_pln(promo, product_pln, pln_rate, buffer) : 0
      unit_discount_pln = [unit_discount_pln, product_pln].min
      discount_total_pln += unit_discount_pln * quantity
      
      unit_price_after_promo_pln = [product_pln - unit_discount_pln, 0].max
      unit_price_with_markup_pln = unit_price_after_promo_pln * (1 + markup_k)
      
      line_total_pln = unit_price_with_markup_pln * quantity
      items_total_pln += line_total_pln

      # BYN значения для отображения
      unit_price_byn = (unit_price_with_markup_pln * pln_rate_with_buffer).round(2)
      line_total_byn = (line_total_pln * pln_rate_with_buffer).round(2)

      # Расчет пошлины для отдельной позиции (line total) для информации
      item_cost_eur = (product_pln * pln_rate / eur_rate).round(2) if eur_rate.positive?
      line_cost_eur = (item_cost_eur || 0) * quantity
      line_weight = weight * quantity
      total_items_cost_eur += line_cost_eur
      
      line_customs = (line_cost_eur.positive? && line_weight.positive?) ? CustomsDutyService.calculate(line_cost_eur, line_weight, eur_rate) : nil

      {
        sku: item.product_sku,
        quantity: quantity,
        unit_price_pln: product_pln,
        unit_price_byn: unit_price_byn,
        unit_discount_pln: unit_discount_pln,
        line_total_pln: line_total_pln,
        line_total_byn: line_total_byn,
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

    # Расчет логистики для ВСЕЙ корзины
    poland_delivery_pln = PolandDeliveryService.calculate(total_weight)
    belarus_delivery_pln = BelarusDeliveryService.calculate(total_weight)

    # Итого в PLN
    total_pln = items_total_pln + poland_delivery_pln + belarus_delivery_pln
    
    # Итого в BYN
    total_byn = (total_pln * pln_rate_with_buffer).round(2)
    
    # Расчет "виртуальных" BYN значений для доставки для UI
    poland_delivery_byn = (poland_delivery_pln * pln_rate_with_buffer).round(2)
    belarus_delivery_byn = (belarus_delivery_pln * pln_rate_with_buffer).round(2)
    delivery_total_byn = (poland_delivery_byn + belarus_delivery_byn).round(2)

    # Динамические правила (минимальный заказ и т.д.)
    # subtotal_new_byn для правил - это сумма ТОВАРОВ с наценкой
    items_total_byn = (items_total_pln * pln_rate_with_buffer).round(2)
    rules = CartRulesService.call(subtotal_new_byn: items_total_byn)

    {
      items: items,
      totals: {
        subtotal_new_byn: items_total_byn, # Для совместимости с CheckoutService
        items_total_byn: items_total_byn,
        delivery_total_byn: delivery_total_byn,
        total_byn: total_byn,
        discount_total_byn: (discount_total_pln * (1 + 0.10) * pln_rate_with_buffer).round(2), # Примерный дисконт в BYN
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

  def self.calculate_unit_discount_pln(promo, price_pln, pln_rate = nil, buffer = nil)
    return 0 unless promo && price_pln.positive?

    case promo.discount_type
    when 'percent'
      (price_pln * promo.discount_value / 100).round(2)
    when 'fixed_pln'
      [promo.discount_value, price_pln].min
    when 'fixed_byn'
      pln_rate ||= ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 1
      buffer ||= PriceCalculationService.exchange_rate_buffer
      discount_pln = promo.discount_value / (pln_rate * buffer)
      [discount_pln, price_pln].min.round(2)
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
