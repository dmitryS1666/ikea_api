# Сервис для расчета итоговой цены товара по новой логике (Март 2026)
class PriceCalculationService
  # Расчет наценки K
  # K = max(min_markup, target_profit / P_pl + markup_offset)
  def self.compute_k(price_zl)
    return min_markup if price_zl.to_f <= 0
    
    target_profit = CalculatorSetting.get('target_profit_pln') || 87.0
    markup_offset = CalculatorSetting.get('markup_offset') || -0.187
    
    k = (target_profit / price_zl.to_f) + markup_offset
    [k, min_markup].max
  end

  def self.min_markup
    CalculatorSetting.get('min_markup') || 0.10
  end

  def self.exchange_rate_buffer
    CalculatorSetting.get('exchange_rate_buffer') || 1.05
  end

  # Расчет цены товара в BYN (только товар + наценка, без доставки)
  # @param product_price_zl [Float] Цена товара в злотых
  # @return [Float] Цена в BYN
  def self.product_price_byn(product_price_zl, pln_rate: nil, buffer: nil)
    product_price_zl = product_price_zl.to_f
    return 0.0 if product_price_zl <= 0

    pln_rate ||= ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
    buffer ||= exchange_rate_buffer
    
    markup_k = compute_k(product_price_zl)
    (product_price_zl * (1 + markup_k) * pln_rate * buffer).round(2)
  end

  # Расчет итоговой цены товара
  # @param product_price_zl [Float] Цена товара в злотых
  # @param weight_kg [Float] Вес товара в килограммах
  # @param use_gls_pickup [Boolean] Использовать пункт отбора GLS
  # @param date [Date, nil] Дата для курсов валют (по умолчанию сегодня)
  # @return [Hash] Детальный расчет цены
  def self.calculate(product_price_zl, weight_kg, use_gls_pickup: false, date: nil)
    date ||= Date.today
    
    # Получаем базовые курсы валют (НБ РБ)
    pln_rate = ExchangeRate.fetch_or_create('PLN', date)&.rate_per_unit
    eur_rate = ExchangeRate.fetch_or_create('EUR', date)&.rate_per_unit
    
    return { error: 'Не удалось получить курсы валют' } unless pln_rate && eur_rate
    
    # 1. Динамическая наценка K
    markup_k = compute_k(product_price_zl)
    
    # 2. Доставка по Польше (в злотых)
    poland_delivery_zl = PolandDeliveryService.calculate(weight_kg, use_gls_pickup: use_gls_pickup)
    
    # 3. Весовая логистика РБ (в злотых за кг)
    # Теперь BelarusDeliveryService возвращает стоимость в PLN
    belarus_delivery_zl = BelarusDeliveryService.calculate(weight_kg)
    
    # 4. Итоговая сумма в PLN
    # priceTotalPLN = P_pl * (1 + K) + deliveryCost + WC_BY
    product_with_markup_zl = product_price_zl * (1 + markup_k)
    total_pln = product_with_markup_zl + poland_delivery_zl + belarus_delivery_zl
    
    # 5. Перевод в BYN
    # priceRb = round(total_pln * ratePLNtoBYN * 1.05, 2)
    buffer = exchange_rate_buffer
    pln_rate_with_buffer = pln_rate * buffer
    total_price_byn = (total_pln * pln_rate_with_buffer).round(2)
    
    # Для совместимости с UI и старыми частями системы рассчитываем "виртуальные" значения в BYN
    product_price_byn = (product_with_markup_zl * pln_rate_with_buffer).round(2)
    poland_delivery_byn = (poland_delivery_zl * pln_rate_with_buffer).round(2)
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
      
      # Доставка и логистика
      poland_delivery_zl: poland_delivery_zl.round(2),
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
