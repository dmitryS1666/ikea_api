# frozen_string_literal: true

class AdminAuditRecorder
  def self.call(record:, action:, changes: {}, metadata: {})
    actor = Current.admin_user
    return unless actor

    AdminAuditLog.create!(
      actor_id: User.exists?(actor.id) ? actor.id : nil,
      auditable_type: record.class.base_class.name,
      auditable_id: record.id,
      action: action,
      resource: record.class.base_class.name.underscore,
      changeset: changes,
      metadata: metadata,
      request_id: Current.request_id,
      ip_address: Current.ip_address,
      created_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("[AdminAuditRecorder] #{e.class}: #{e.message}")
    nil
  end
end
