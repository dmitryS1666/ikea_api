class ReturnRequest < ApplicationRecord
  STATUSES = %w[new in_review approved rejected completed].freeze

  belongs_to :user
  belongs_to :order

  has_many_attached :attachments

  validates :reason, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(created_at: :desc) }
end
