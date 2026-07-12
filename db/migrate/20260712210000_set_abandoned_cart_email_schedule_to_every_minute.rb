# frozen_string_literal: true

class SetAbandonedCartEmailScheduleToEveryMinute < ActiveRecord::Migration[7.1]
  TASK_TYPE = "send_abandoned_cart_emails"

  class MigrationCronSchedule < ActiveRecord::Base
    self.table_name = "cron_schedules"
  end

  def up
    unless index_exists?(:orders, :updated_at, name: "index_orders_on_pending_abandoned_cart_email")
      add_index :orders,
                :updated_at,
                name: "index_orders_on_pending_abandoned_cart_email",
                where: "checkout_draft = TRUE AND abandoned_cart_email_sent_at IS NULL"
    end

    schedule = MigrationCronSchedule.find_or_initialize_by(task_type: TASK_TYPE)
    schedule.schedule = "* * * * *"
    schedule.enabled = true
    schedule.next_run_at = Time.current if schedule.has_attribute?(:next_run_at)
    schedule.save!
  end

  def down
    remove_index :orders, name: "index_orders_on_pending_abandoned_cart_email", if_exists: true

    schedule = MigrationCronSchedule.find_by(task_type: TASK_TYPE)
    return unless schedule

    schedule.update!(schedule: "0 * * * *")
  end
end
