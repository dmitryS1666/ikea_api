# frozen_string_literal: true

class SetCustomsFreeCostLimitTo200Eur < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:calculator_settings)

    setting = CalculatorSetting.find_by(key: "customs_free_cost_limit")
    return if setting && setting.decimal_value.to_f == 200.0

    CalculatorSetting.set(
      "customs_free_cost_limit",
      200.0,
      setting_type: "decimal",
      description: "Беспошлинный лимит по таможенной базе C (EUR). При C = лимиту пошлины нет, при C > лимита появляется."
    )
  end

  def down
    return unless table_exists?(:calculator_settings)

    setting = CalculatorSetting.find_by(key: "customs_free_cost_limit")
    return unless setting && setting.decimal_value.to_f == 200.0

    CalculatorSetting.set(
      "customs_free_cost_limit",
      150.0,
      setting_type: "decimal",
      description: "Беспошлинный лимит по таможенной базе C (EUR). При C = лимиту пошлины нет, при C > лимита появляется."
    )
  end
end
