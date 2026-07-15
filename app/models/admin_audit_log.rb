# frozen_string_literal: true

class AdminAuditLog < ApplicationRecord
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :auditable, polymorphic: true, optional: true

  validates :action, :resource, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def readonly?
    persisted?
  end

  before_destroy { throw(:abort) }
end
