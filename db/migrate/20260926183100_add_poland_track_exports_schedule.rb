class AddPolandTrackExportsSchedule < ActiveRecord::Migration[7.1]
  def up
    CronSchedule.find_or_create_by!(task_type: "poland_track_exports") do |schedule|
      schedule.schedule = "* * * * *"
      schedule.enabled = true
    end
  end

  def down
    CronSchedule.where(task_type: "poland_track_exports").delete_all
  end
end
