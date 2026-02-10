class A1Verification < ApplicationRecord
  STATUSES = %w[pending verified expired].freeze

  belongs_to :user, optional: true

  validates :phone, presence: true
  validates :context, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :expected_last4, presence: true
  validates :expires_at, presence: true

  scope :active, -> { where(status: 'pending').where('expires_at > ?', Time.current) }

  def expired?
    expires_at < Time.current
  end
end
