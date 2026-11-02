# frozen_string_literal: true

# Checkout UI already shows Europost bulky limits (50 kg / 250 cm / 350 cm sum),
# but code defaults were still standard parcel limits (30 / 105 / 180). That made
# multi-package sofas like LILLEHEM fall back to ikeya_delivery with a callback
# instead of a calculated courier price.
class AlignEuropostVghLimitsWithBulkyRules < ActiveRecord::Migration[7.1]
  TARGETS = {
    "europost_max_weight_kg" => {
      value: 50.0,
      description: "Макс. вес одной посылки для Europost courier/ПВЗ (кг). До 50 кг; ПВЗ с лимитом 30 кг отфильтруются отдельно."
    },
    "europost_max_volume_m3" => {
      value: 2.0,
      description: "Мягкий верхний порог объёма одной посылки для Europost (м³). Европочта публикует лимиты по сторонам, не по м³."
    },
    "europost_max_dimension_cm" => {
      value: 250.0,
      description: "Макс. сторона посылки Europost для юрлиц/громоздких (см)."
    },
    "europost_max_dimensions_sum_cm" => {
      value: 350.0,
      description: "Макс. сумма трёх сторон посылки Europost для юрлиц/громоздких (см)."
    }
  }.freeze

  PREVIOUS = {
    "europost_max_weight_kg" => 30.0,
    "europost_max_volume_m3" => 0.25,
    "europost_max_dimension_cm" => 105.0,
    "europost_max_dimensions_sum_cm" => 180.0
  }.freeze

  def up
    return unless table_exists?(:calculator_settings)

    TARGETS.each do |key, meta|
      CalculatorSetting.set(
        key,
        meta[:value],
        setting_type: "decimal",
        description: meta[:description]
      )
    end
  end

  def down
    return unless table_exists?(:calculator_settings)

    PREVIOUS.each do |key, value|
      setting = CalculatorSetting.find_by(key: key)
      next unless setting

      target = TARGETS[key]
      next unless setting.decimal_value.to_f == target[:value]

      CalculatorSetting.set(
        key,
        value,
        setting_type: "decimal",
        description: target[:description]
      )
    end
  end
end
