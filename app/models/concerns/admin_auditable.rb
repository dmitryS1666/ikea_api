# frozen_string_literal: true

module AdminAuditable
  extend ActiveSupport::Concern

  FILTERED_ATTRIBUTE_PATTERN = /password|token|secret|encrypted|phone|email|address|body|comment|message/i

  included do
    after_create_commit { record_admin_audit("create") }
    after_update_commit { record_admin_audit("update") }
    after_destroy_commit { record_admin_audit("destroy") }
  end

  private

  def record_admin_audit(action)
    return unless Current.admin_user
    return if is_a?(AdminAuditLog)

    AdminAuditRecorder.call(record: self, action: action, changes: audit_changes_for(action))
  end

  def audit_changes_for(action)
    raw = action == "destroy" ? attributes : saved_changes

    raw.except("created_at", "updated_at").each_with_object({}) do |(attribute, value), result|
      result[attribute] = if attribute.match?(FILTERED_ATTRIBUTE_PATTERN)
                            "[FILTERED]"
                          else
                            value
                          end
    end
  end
end
