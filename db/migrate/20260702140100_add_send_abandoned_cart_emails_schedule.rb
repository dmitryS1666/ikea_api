class AddSendAbandonedCartEmailsSchedule < ActiveRecord::Migration[7.1]
  TASK_TYPE = "send_abandoned_cart_emails"

  def up
    return if CronSchedule.exists?(task_type: TASK_TYPE)

    CronSchedule.create!(
      task_type: TASK_TYPE,
      schedule: "0 * * * *",
      enabled: true
    )
  end

  def down
    CronSchedule.where(task_type: TASK_TYPE).delete_all
  end
end
