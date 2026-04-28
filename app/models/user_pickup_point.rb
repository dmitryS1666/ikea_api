class UserPickupPoint < ApplicationRecord
  SUPPORTED_PROVIDERS = %w[europost].freeze

  belongs_to :user
  belongs_to :pickup_point, optional: true

  scope :alive, -> { where(deleted_at: nil) }

  validates :provider, presence: true, inclusion: { in: SUPPORTED_PROVIDERS }
  validates :external_id, presence: true
end
