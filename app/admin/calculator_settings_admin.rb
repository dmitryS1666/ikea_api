Trestle.resource(:calculator_settings, model: CalculatorSetting) do
  TRACKED_KEYS = %w[
    target_profit_pln
    markup_offset
    min_markup
    exchange_rate_buffer
    belarus_delivery_rates
    poland_delivery_rates
    customs_free_cost_limit
    customs_free_weight_limit
    customs_cost_duty_rate
    customs_weight_duty_rate
    customs_fee
    default_delivery_days
    show_delivery_block_global
    show_reviews_block_global
    show_tips_block_global
  ] unless defined?(TRACKED_KEYS)

  menu do
    item :calculator_settings, icon: "fa fa-cogs", label: "Настройки расчета", group: "Marketing"
  end

  collection do
    CalculatorSetting.where(key: TRACKED_KEYS)
  end

  table do
    column :key, link: true
    column :value
    column :setting_type
    column :updated_at
    actions
  end

  form do |setting|
    select :key, TRACKED_KEYS.map { |key| [key.humanize, key] }, label: "Ключ"
    
    if setting.key&.end_with?('_global')
      select :setting_type, [['Boolean (0/1)', 'integer']], label: "Тип настройки"
      select :value, [['Включено', '1'], ['Выключено', '0']], label: "Значение"
    elsif %w[belarus_delivery_rates poland_delivery_rates].include?(setting.key)
      hidden_field :setting_type, value: 'json'
      text_area :value, rows: 10, label: "Значение (JSON)"
    else
      hidden_field :setting_type, value: 'decimal'
      number_field :value, step: 0.0001
    end
    
    text_field :description
  end
end
