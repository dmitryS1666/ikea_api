# frozen_string_literal: true

module RequestWorkflowTrackable
  extend ActiveSupport::Concern

  included do
    belongs_to :assigned_to, class_name: "User", optional: true
    has_many :request_activities, as: :trackable, dependent: :destroy

    after_create_commit :record_request_created_activity
    after_update_commit :record_request_workflow_changes
  end

  private

  def record_request_created_activity
    request_activities.create!(
      activity_type: "created",
      actor: Current.admin_user,
      to_status: workflow_status,
      metadata: workflow_metadata
    )
  end

  def record_request_workflow_changes
    if saved_change_to_attribute?("status")
      request_activities.create!(
        activity_type: "status_changed",
        actor: Current.admin_user,
        from_status: workflow_status_before_last_save,
        to_status: workflow_status,
        metadata: workflow_metadata
      )
    end

    return unless saved_change_to_attribute?("assigned_to_id")

    request_activities.create!(
      activity_type: "assigned",
      actor: Current.admin_user,
      assignee: assigned_to,
      metadata: workflow_metadata.merge(previous_assignee_id: assigned_to_id_before_last_save)
    )
  end

  def workflow_status
    respond_to?(:status) ? status.to_s : nil
  end

  def workflow_status_before_last_save
    value = attribute_before_last_save("status")
    return value.to_s unless self.class.respond_to?(:statuses)

    self.class.statuses.key(value) || value.to_s
  end

  def workflow_metadata
    { source: Current.admin_user.present? ? "admin" : "system" }
  end
end
