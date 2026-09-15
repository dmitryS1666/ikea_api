# Сервис для расчета таможенной пошлины
class CustomsDutyService
  # Получить лимиты и ставки из настроек
  def self.free_cost_limit
    Pricing::Settings.customs_free_cost_limit.to_f
  end

  def self.free_weight_limit
    Pricing::Settings.customs_free_weight_limit.to_f
  end

  def self.cost_duty_rate
    Pricing::Settings.customs_cost_duty_rate.to_f
  end

  def self.weight_duty_rate
    Pricing::Settings.customs_weight_duty_rate.to_f
  end

  def self.customs_fee
    Pricing::Settings.customs_fee.to_f
  end
  
  # Расчет таможенной пошлины
  # @param cost_eur [Float] Стоимость товара в евро
  # @param weight_kg [Float] Вес товара в килограммах
  # @param eur_rate [Float] Курс евро к BYN (от НБ РБ)
  # @return [Hash] Хеш с деталями расчета: { duty: Float, fee: Float, total: Float, details: Hash }
  def self.calculate(cost_eur, weight_kg, eur_rate)
    cost = Pricing::Money.bd(cost_eur) || BigDecimal("0")
    weight = Pricing::Money.bd(weight_kg) || BigDecimal("0")
    rate = Pricing::Money.bd(eur_rate) || BigDecimal("0")

    cost_limit = Pricing::Money.bd(free_cost_limit)
    weight_limit = Pricing::Money.bd(free_weight_limit)
    
    # Проверяем превышение лимитов
    cost_exceeded = cost > cost_limit
    weight_exceeded = weight > weight_limit
    
    duty_eur = 0.0
    details = {
      cost_limit_exceeded: cost_exceeded,
      weight_limit_exceeded: weight_exceeded,
      cost_excess: cost_exceeded ? (cost - cost_limit).round(2) : 0.0,
      weight_excess: weight_exceeded ? (weight - weight_limit).round(2) : 0.0
    }
    
    if !cost_exceeded && !weight_exceeded
      # Сценарий 4: В пределах нормы (без пошлины)
      details[:scenario] = 4
      details[:duty_by_cost_eur] = 0.0
      details[:duty_by_weight_eur] = 0.0
      duty_eur = 0.0
    elsif cost_exceeded && !weight_exceeded
      # Сценарий 1: Превышение только стоимостного лимита
      details[:scenario] = 1
      duty_eur = (cost - cost_limit) * cost_duty_rate
      details[:duty_by_cost_eur] = duty_eur.round(2)
      details[:duty_by_weight_eur] = 0.0
    elsif !cost_exceeded && weight_exceeded
      # Сценарий 2: Превышение только весового лимита
      details[:scenario] = 2
      duty_eur = (weight - weight_limit) * weight_duty_rate
      details[:duty_by_cost_eur] = 0.0
      details[:duty_by_weight_eur] = duty_eur.round(2)
    else
      # Сценарий 3: Двойное превышение
      details[:scenario] = 3
      duty_by_cost_eur = (cost - cost_limit) * cost_duty_rate
      duty_by_weight_eur = (weight - weight_limit) * weight_duty_rate
      
      # Выбираем максимальную пошлину
      duty_eur = [duty_by_cost_eur, duty_by_weight_eur].max
      details[:duty_by_cost_eur] = duty_by_cost_eur.round(2)
      details[:duty_by_weight_eur] = duty_by_weight_eur.round(2)
      details[:max_duty_used] = duty_by_cost_eur > duty_by_weight_eur ? 'cost' : 'weight'
    end
    
    duty_byn = Pricing::Money.round2(duty_eur * rate) || BigDecimal("0")
    fee_byn = (cost_exceeded || weight_exceeded) ? (Pricing::Money.bd(customs_fee) || BigDecimal("0")) : BigDecimal("0")
    total_byn = duty_byn + fee_byn

    {
      duty_eur: Pricing::Money.to_f_round2(duty_eur),
      duty_byn: duty_byn.to_f,
      fee_byn: Pricing::Money.to_f_round2(fee_byn),
      total_byn: Pricing::Money.to_f_round2(total_byn),
      details: details
    }
  end
end

