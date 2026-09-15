# frozen_string_literal: true

class SeedIkeaDeliveryTariffs < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:calculator_settings)
    return unless table_exists?(:products)

    CalculatorSetting.replace_placeholder_ikea_delivery_config!

    if column_exists?(:products, :delivery_cost_manual)
      execute <<~SQL.squish
        UPDATE products
        SET delivery_cost_manual = FALSE
        WHERE delivery_cost_manual = TRUE
      SQL
    end

    Products::RecalculateIkeaDeliveryJob.perform_later if defined?(Products::RecalculateIkeaDeliveryJob)
  end

  def down
    # Тарифы оставляем: откат к пустому placeholder ломал бы витрину.
  end
end
