# frozen_string_literal: true

class AlignStorefrontTariffsWithParser < ActiveRecord::Migration[7.1]
  PARSER_BELARUS_RATES = {
    "0-20" => 16.85,
    "20-30" => 12.81,
    "30-40" => 10.69,
    "40-1000" => 8.58
  }.freeze

  WITHOUT_CARRY_COSTS = {
    "transport_no_carry_0_50" => 69.0,
    "transport_no_carry_50_100" => 99.0,
    "transport_no_carry_100_200" => 159.0
  }.freeze

  def up
    return unless table_exists?(:calculator_settings)

    CalculatorSetting.set(
      "belarus_delivery_rates",
      PARSER_BELARUS_RATES,
      setting_type: "json",
      description: "WC: PLN за кг по диапазонам веса одной единицы. Шкала не прогрессивная: для всего веса берётся ставка диапазона."
    )

    setting = CalculatorSetting.find_by(key: "ikea_delivery_config")
    config = setting&.json_value || CalculatorSetting.default_ikea_delivery_config
    Array(config["methods"]).each do |method|
      cost = WITHOUT_CARRY_COSTS[method["code"].to_s]
      method["cost_pln"] = cost if cost
    end

    CalculatorSetting.set(
      "ikea_delivery_config",
      config,
      setting_type: "json",
      description: "Конфиг D_IKEA. Посылка IKEA до 30 кг — пункт GLS 0 PLN. Иначе без заноса: 69/99/159 PLN."
    )

    Products::RecalculateIkeaDeliveryJob.perform_later if defined?(Products::RecalculateIkeaDeliveryJob)
  end

  def down
    # Предыдущее значение belarus_delivery_rates на проде не было в коде.
  end
end
