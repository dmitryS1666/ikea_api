# frozen_string_literal: true

class AddSeoCatalogPagesCronSchedule < ActiveRecord::Migration[7.1]
  TASK_TYPE = "seo_catalog_pages"
  # Daily safety regeneration after the PL prices/stock cron.
  # The PL prices/stock cron is seeded at 05:00, and RefreshPlPricesAndStockJob
  # also enqueues RegenerateSeoCatalogPagesJob after a successful catalog update.
  SCHEDULE = "0 8 * * *"

  def up
    return unless table_exists?(:cron_schedules)

    execute <<~SQL.squish
      INSERT INTO cron_schedules (task_type, schedule, enabled, created_at, updated_at)
      VALUES ('#{TASK_TYPE}', '#{SCHEDULE}', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (task_type) DO UPDATE SET
        schedule = EXCLUDED.schedule,
        enabled = TRUE,
        updated_at = CURRENT_TIMESTAMP
    SQL
  end

  def down
    return unless table_exists?(:cron_schedules)

    execute "DELETE FROM cron_schedules WHERE task_type = '#{TASK_TYPE}'"
  end
end
