class DeliveryEtaService
  # TODO: remove constants when settings become mandatory in all envs.
  SAFE_DEFAULT_DELIVERY_DAYS = 14
  SAFE_DEFAULT_STORAGE_DAYS = 14

  def self.call(order_date: Date.current, with_storage: false)
    delivery_days = CalculatorSetting.get('delivery_days_default') ||
                    CalculatorSetting.get('default_delivery_days') ||
                    SAFE_DEFAULT_DELIVERY_DAYS

    base_delivery_date = order_date.to_date + delivery_days.to_i.days
    delivery_date = move_weekend_to_monday(base_delivery_date)

    storage_until = nil
    if with_storage
      storage_days = CalculatorSetting.get('europost_storage_days') || SAFE_DEFAULT_STORAGE_DAYS
      storage_until = delivery_date + storage_days.to_i.days
    end

    {
      delivery_date: delivery_date,
      storage_until: storage_until
    }
  end

  def self.move_weekend_to_monday(date)
    case date.wday
    when 6 # Saturday
      date + 2.days
    when 0 # Sunday
      date + 1.day
    else
      date
    end
  end
end
