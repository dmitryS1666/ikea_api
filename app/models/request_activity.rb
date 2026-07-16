# frozen_string_literal: true

class RequestActivity < ApplicationRecord
  ACTIVITY_TYPES = %w[created comment assigned status_changed].freeze

  belongs_to :trackable, polymorphic: true
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :assignee, class_name: "User", optional: true

  validates :activity_type, presence: true, inclusion: { in: ACTIVITY_TYPES }
  validates :body, presence: true, if: -> { activity_type == "comment" }

  scope :ordered, -> { order(created_at: :asc, id: :asc) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :comments, -> { where(activity_type: "comment") }

  ACTIVITY_TYPES.each do |type|
    define_method(:"#{type}?") { activity_type == type }
  end

  def actor_name
    actor&.full_name || "Система"
  end
end
