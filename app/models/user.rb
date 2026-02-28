class User < ApplicationRecord
  include Trestle::Auth::ModelMethods
  include Trestle::Auth::ModelMethods::Rememberable
  
  has_secure_password(validations: false)
  
  validates :username, presence: true
  validates :phone, presence: true, uniqueness: true
  validates :email, uniqueness: true, allow_nil: true, allow_blank: true
  validates :role, inclusion: { in: %w[user admin manager] }
  validates :country_code, inclusion: { in: %w[RB РФ РК] }, allow_blank: true
  validates :password, presence: true, on: :create, if: -> { role == 'admin' || role == 'manager' }
  
  scope :active, -> { where(is_active: true) }

  has_many :orders, dependent: :nullify
  has_many :reviews, dependent: :nullify
  has_many :return_requests, dependent: :destroy
  has_one :cart, dependent: :destroy
  has_one :favorite, dependent: :destroy
  
  def admin?
    role == 'admin'
  end
  
  def manager?
    role == 'manager'
  end
  
  # Методы для Trestle Auth
  def first_name
    username.split(' ').first || username
  end
  
  def last_name
    username.split(' ').last || ''
  end

  # Passport storage (encrypted locally; CRM integration is skipped for now)
  encrypts :encrypted_passport_json, deterministic: false

  def passport_data
    return nil if encrypted_passport_json.blank?
    JSON.parse(encrypted_passport_json)
  rescue JSON::ParserError
    nil
  end

  def passport_verified?
    passport_verified_at.present?
  end
end
