class EmailVerificationToken < ApplicationRecord
  PURPOSES = %w[welcome email_change].freeze
  TTL = 24.hours

  belongs_to :user

  validates :email, presence: true
  validates :token, presence: true, uniqueness: true
  validates :purpose, presence: true, inclusion: { in: PURPOSES }
  validates :expires_at, presence: true

  scope :active, -> { where(verified_at: nil).where("expires_at > ?", Time.current) }

  def expired?
    expires_at.blank? || expires_at <= Time.current
  end

  def verified?
    verified_at.present?
  end

  def verify!
    update!(verified_at: Time.current)
  end
end
