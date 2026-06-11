class AddCancelExpiredUnpaidOrdersSchedule < ActiveRecord::Migration[7.1]
  INDEX_NAME = "index_orders_on_unpaid_payment_expiration"
  TASK_TYPE = "cancel_expired_unpaid_orders"
  SCHEDULE = "*/5 * * * *"

  def up
    add_index :orders,
              [:status, :checkout_draft, :payment_expires_at],
              name: INDEX_NAME,
              where: "payment_expires_at IS NOT NULL" unless index_exists?(
                :orders, [:status, :checkout_draft, :payment_expires_at], name: INDEX_NAME
              )

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
    remove_index :orders, name: INDEX_NAME if index_exists?(
      :orders, [:status, :checkout_draft, :payment_expires_at], name: INDEX_NAME
    )

    return unless table_exists?(:cron_schedules)

    execute "DELETE FROM cron_schedules WHERE task_type = '#{TASK_TYPE}'"
  end
end
