# Сервис для расчета итоговой цены товара (PLN → BYN по новой политике cheap/k)
class PriceCalculationService
  TARGET_PROFIT_PLN = 87.0
  MARKUP_SUBTRAHEND = 0.187
  MIN_MARKUP = 0.10
  CHEAP_MULTIPLIER = 1.3
  PRICE_CHEAP_THRESHOLD_PLN_DEFAULT = 150.0

  def self.compute_k(price_zl)
    return MIN_MARKUP if price_zl.to_f <= 0

    k = (TARGET_PROFIT_PLN / price_zl.to_f) - MARKUP_SUBTRAHEND
    [k, MIN_MARKUP].max
  end

  def self.cheap_threshold_pln
    raw = ENV.fetch("PRICE_CHEAP_THRESHOLD_PLN", PRICE_CHEAP_THRESHOLD_PLN_DEFAULT.to_s)
    threshold = raw.to_f
    threshold.positive? ? threshold : PRICE_CHEAP_THRESHOLD_PLN_DEFAULT
  rescue StandardError
    PRICE_CHEAP_THRESHOLD_PLN_DEFAULT
  end

  def self.pricing_mode_for(price_zl)
    price_zl.to_f <= cheap_threshold_pln ? :cheap : :k
  end

  def self.exchange_rate_buffer
    CalculatorSetting.get('exchange_rate_buffer') || 1.05
  end

  # Полная сумма в PLN для строки корзины/товара по новой формуле.
  # mode выбирается по цене единицы товара (PLN).
  def self.line_total_pln(unit_price_zl:, quantity:, weight_kg:, delivery_unit_pln:)
    qty = quantity.to_i
    return 0.0 if qty <= 0

    breakdown = line_breakdown_pln(
      unit_price_zl: unit_price_zl,
      quantity: qty,
      weight_kg: weight_kg,
      delivery_unit_pln: delivery_unit_pln
    )

    breakdown[:total_pln].round(2)
  end

  def self.line_breakdown_pln(unit_price_zl:, quantity:, weight_kg:, delivery_unit_pln:)
    unit_price = unit_price_zl.to_f
    qty = quantity.to_i
    return empty_line_breakdown if unit_price <= 0 || qty <= 0

    goods_pln = unit_price * qty
    delivery_pln = delivery_unit_pln.to_f * qty
    wc_by_pln = BelarusDeliveryService.calculate(weight_kg.to_f)

    mode = pricing_mode_for(unit_price)
    if mode == :cheap
      base_pln = goods_pln + delivery_pln + wc_by_pln
      total_pln = base_pln * CHEAP_MULTIPLIER
      markup_k = 0.0
    else
      markup_k = compute_k(unit_price)
      goods_with_markup_pln = goods_pln * (1 + markup_k)
      total_pln = goods_with_markup_pln + delivery_pln + wc_by_pln
      base_pln = nil
    end

    {
      mode: mode,
      markup_k: markup_k,
      goods_pln: goods_pln.round(2),
      delivery_pln: delivery_pln.round(2),
      wc_by_pln: wc_by_pln.round(2),
      base_pln: base_pln&.round(2),
      total_pln: total_pln.round(2)
    }
  end

  def self.empty_line_breakdown
    {
      mode: :cheap,
      markup_k: 0.0,
      goods_pln: 0.0,
      delivery_pln: 0.0,
      wc_by_pln: 0.0,
      base_pln: 0.0,
      total_pln: 0.0
    }
  end

  # Компоненты строки в BYN: товар с наценкой, доставка PL, доставка в РБ, итого.
  def self.line_byn_components(unit_price_zl:, quantity: 1, weight_kg: nil, delivery_unit_pln: 0, pln_rate: nil, buffer: nil, date: nil)
    unit_price_zl = unit_price_zl.to_f
    return empty_line_byn_components if unit_price_zl <= 0

    breakdown = line_breakdown_pln(
      unit_price_zl: unit_price_zl,
      quantity: quantity,
      weight_kg: weight_kg.to_f,
      delivery_unit_pln: delivery_unit_pln.to_f
    )

    date ||= Date.today
    pln_rate ||= ExchangeRate.fetch_or_create('PLN', date)&.rate_per_unit || 0
    buffer ||= exchange_rate_buffer
    rate = pln_rate * buffer

    if breakdown[:mode] == :cheap
      multiplier = CHEAP_MULTIPLIER
      {
        goods_byn: (breakdown[:goods_pln] * multiplier * rate).round(2),
        delivery_poland_byn: (breakdown[:delivery_pln] * multiplier * rate).round(2),
        delivery_belarus_byn: (breakdown[:wc_by_pln] * multiplier * rate).round(2),
        total_byn: (breakdown[:total_pln] * rate).round(2)
      }
    else
      markup_k = breakdown[:markup_k]
      {
        goods_byn: (breakdown[:goods_pln] * (1 + markup_k) * rate).round(2),
        delivery_poland_byn: (breakdown[:delivery_pln] * rate).round(2),
        delivery_belarus_byn: (breakdown[:wc_by_pln] * rate).round(2),
        total_byn: (breakdown[:total_pln] * rate).round(2)
      }
    end
  end

  def self.empty_line_byn_components
    {
      goods_byn: 0.0,
      delivery_poland_byn: 0.0,
      delivery_belarus_byn: 0.0,
      total_byn: 0.0
    }
  end

  # Витринная цена для карточки/каталога: без доставки в Беларусь (как «Стоимость товаров» в корзине).
  def self.product_storefront_price_byn(product_price_zl, weight_kg: nil, delivery_pln: nil, pln_rate: nil, buffer: nil, date: nil)
    components = line_byn_components(
      unit_price_zl: product_price_zl,
      quantity: 1,
      weight_kg: weight_kg,
      delivery_unit_pln: delivery_pln.nil? ? 0.0 : delivery_pln.to_f,
      pln_rate: pln_rate,
      buffer: buffer,
      date: date
    )

    (components[:goods_byn] + components[:delivery_poland_byn]).round(2)
  end

  # Полная цена строки в BYN (товар + вся логистика).
  # @param weight_kg [Float, nil] если nil или 0 — WC_BY=0
  # @param delivery_pln [Float, nil] если nil — доставка в PLN не добавляется
  def self.product_price_byn(product_price_zl, weight_kg: nil, delivery_pln: nil, pln_rate: nil, buffer: nil, date: nil)
    line_byn_components(
      unit_price_zl: product_price_zl,
      quantity: 1,
      weight_kg: weight_kg,
      delivery_unit_pln: delivery_pln.nil? ? 0.0 : delivery_pln.to_f,
      pln_rate: pln_rate,
      buffer: buffer,
      date: date
    )[:total_byn]
  end

  # Расчет итоговой цены товара для админ-калькулятора
  # @param product_price_zl [Float] Цена товара в злотых
  # @param weight_kg [Float] Вес товара в килограммах
  # @param use_gls_pickup [Boolean] Использовать пункт отбора GLS
  # @param date [Date, nil] Дата для курсов валют (по умолчанию сегодня)
  # @return [Hash] Детальный расчет цены
  def self.calculate(product_price_zl, weight_kg, use_gls_pickup: false, delivery_pln: nil, date: nil)
    date ||= Date.today
    
    # Получаем базовые курсы валют (НБ РБ)
    pln_rate = ExchangeRate.fetch_or_create('PLN', date)&.rate_per_unit
    eur_rate = ExchangeRate.fetch_or_create('EUR', date)&.rate_per_unit
    
    return { error: 'Не удалось получить курсы валют' } unless pln_rate && eur_rate
    
    # 1. Доставка в PLN: явное значение (как delivery_cost у товара) или тариф по Польше
    delivery_zl = if delivery_pln.nil?
                    PolandDeliveryService.calculate(weight_kg, use_gls_pickup: use_gls_pickup)
                  else
                    delivery_pln.to_f
                  end

    breakdown = line_breakdown_pln(
      unit_price_zl: product_price_zl,
      quantity: 1,
      weight_kg: weight_kg,
      delivery_unit_pln: delivery_zl
    )
    total_pln = breakdown[:total_pln]
    belarus_delivery_zl = breakdown[:wc_by_pln]
    markup_k = breakdown[:markup_k]
    pricing_mode = breakdown[:mode]
    
    # 2. Перевод в BYN: round(total_pln × курс_PLN_BYN × exchange_rate_buffer, 2), buffer по умолчанию 1.05
    buffer = exchange_rate_buffer
    pln_rate_with_buffer = pln_rate * buffer
    total_price_byn = (total_pln * pln_rate_with_buffer).round(2)
    
    # Для UI: составляющие в BYN
    goods_component_pln =
      if pricing_mode == :cheap
        # В cheap режиме множитель применяется к всей базе, поэтому "товарный" компонент
        # в UI оставляем как цена IKEA без разбиения коэффициента.
        product_price_zl
      else
        product_price_zl * (1 + markup_k)
      end
    product_price_byn = (goods_component_pln * pln_rate_with_buffer).round(2)
    poland_delivery_byn = (delivery_zl * pln_rate_with_buffer).round(2)
    belarus_delivery_byn = (belarus_delivery_zl * pln_rate_with_buffer).round(2)

    # Таможенная пошлина (в новой логике пока не учитывается в общей сумме, 
    # но можем рассчитать для информации)
    product_price_eur = (product_price_zl * pln_rate / eur_rate).round(2)
    customs = CustomsDutyService.calculate(product_price_eur, weight_kg, eur_rate)
    
    {
      product_price_zl: product_price_zl.round(2),
      product_price_byn: product_price_byn,
      weight_kg: weight_kg.round(2),
      markup_k: markup_k.round(4),
      pricing_mode: pricing_mode.to_s,
      cheap_threshold_pln: cheap_threshold_pln.round(2),
      cheap_multiplier: CHEAP_MULTIPLIER,
      
      # Доставка и логистика
      delivery_pln: delivery_zl.round(2),
      poland_delivery_zl: delivery_zl.round(2), # legacy key: фактическая доставка в PLN
      poland_delivery_byn: poland_delivery_byn,
      belarus_delivery_zl: belarus_delivery_zl.round(2),
      belarus_delivery_byn: belarus_delivery_byn,
      
      # Курсы и буфер
      pln_rate: pln_rate.round(4),
      eur_rate: eur_rate.round(4),
      exchange_rate_buffer: buffer,
      pln_rate_with_buffer: pln_rate_with_buffer.round(4),
      
      # Таможенная пошлина (информативно)
      customs_duty_eur: customs[:duty_eur],
      customs_duty_byn: customs[:duty_byn],
      customs_fee_byn: customs[:fee_byn],
      customs_total_byn: customs[:total_byn],
      customs_details: customs[:details],
      
      # Итого
      total_pln: total_pln.round(2),
      total_price_byn: total_price_byn,
      
      # Детализация
      breakdown: {
        product: product_price_byn,
        poland_delivery: poland_delivery_byn,
        belarus_delivery: belarus_delivery_byn,
        customs: 0, # В новой формуле таможня не включена в total_price_byn
        total: total_price_byn
      }
    }
  end
end
