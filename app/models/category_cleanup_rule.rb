class CategoryCleanupRule < ApplicationRecord
  ACTIONS = %w[keep delete merge skip review].freeze
  RESOLUTION_STATUSES = %w[pending resolved ambiguous failed applied skipped].freeze

  validates :source_row_no, presence: true, uniqueness: true
  validates :raw_status, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :resolution_status, inclusion: { in: RESOLUTION_STATUSES }

  belongs_to :resolved_source_category,
             class_name: 'Category',
             foreign_key: :resolved_source_ikea_id,
             primary_key: :ikea_id,
             optional: true

  belongs_to :resolved_target_category,
             class_name: 'Category',
             foreign_key: :resolved_target_ikea_id,
             primary_key: :ikea_id,
             optional: true

  scope :pending_resolution, -> { where(resolution_status: 'pending') }
  scope :resolved, -> { where(resolution_status: 'resolved') }
  scope :for_apply, -> { where(resolution_status: 'resolved').where(action: %w[delete merge]) }
end
