# frozen_string_literal: true

class AddPlPricesStockCronSchedule < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:cron_schedules)

    execute <<-SQL.squish
      INSERT INTO cron_schedules (task_type, schedule, enabled, created_at, updated_at)
      SELECT 'pl_prices_stock', '0 5 * * *', true, NOW(), NOW()
      WHERE NOT EXISTS (SELECT 1 FROM cron_schedules WHERE task_type = 'pl_prices_stock' LIMIT 1)
    SQL
  end

  def down
    execute <<-SQL.squish
      DELETE FROM cron_schedules WHERE task_type = 'pl_prices_stock'
    SQL
  end
end
