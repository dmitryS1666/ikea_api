class BackfillMarkupSubtrahendCalculatorSetting < ActiveRecord::Migration[7.1]
  class LegacyCalculatorSetting < ActiveRecord::Base
    self.table_name = 'calculator_settings'
  end

  def up
    return unless table_exists?(:calculator_settings)
    return if LegacyCalculatorSetting.exists?(key: 'markup_subtrahend')

    val = 0.187
    if (row = LegacyCalculatorSetting.find_by(key: 'markup_offset'))
      val = -row.value.to_f
    end

    LegacyCalculatorSetting.create!(
      key: 'markup_subtrahend',
      value: val.to_s,
      setting_type: 'decimal',
      description: 'Вычитаемое в формуле K (K = target_profit_pln / цена_PLN − это значение, не ниже min_markup)'
    )
  end

  def down
    LegacyCalculatorSetting.where(key: 'markup_subtrahend').delete_all if table_exists?(:calculator_settings)
  end
end
