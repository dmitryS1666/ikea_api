# frozen_string_literal: true

module Admin
  class RequestWorkflowService
    def self.add_comment!(record:, actor:, body:)
      text = body.to_s.strip
      raise ArgumentError, "Комментарий не может быть пустым" if text.blank?

      record.request_activities.create!(
        activity_type: "comment",
        actor: actor,
        body: text,
        metadata: { source: "admin" }
      )
    end
  end
end
