class User < ApplicationRecord
  has_secure_password
  
  validates :username, presence: true, uniqueness: true
  validates :email, uniqueness: true, allow_nil: true
  validates :role, inclusion: { in: %w[user admin] }
  
  scope :active, -> { where(is_active: true) }
end
