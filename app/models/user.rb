class User < ApplicationRecord
  include Trestle::Auth::ModelMethods
  include Trestle::Auth::ModelMethods::Rememberable

  CANONICAL_GENDERS = %w[Male Female].freeze
  GENDER_OPTIONS = [["Мужской", "Male"], ["Женский", "Female"]].freeze
  GENDER_ALIASES = {
    "male" => "Male",
    "m" => "Male",
    "man" => "Male",
    "мужской" => "Male",
    "мужчина" => "Male",
    "м" => "Male",
    "female" => "Female",
    "f" => "Female",
    "woman" => "Female",
    "женский" => "Female",
    "женщина" => "Female",
    "ж" => "Female"
  }.freeze

  has_secure_password(validations: false)
  
  validates :username, presence: true
  validates :phone, presence: true, uniqueness: true
  validates :email, uniqueness: true, allow_nil: true, allow_blank: true
  validates :role, inclusion: { in: %w[user admin manager] }
  validates :country_code, inclusion: { in: %w[RB РФ РК] }, allow_blank: true
  validates :gender, inclusion: { in: CANONICAL_GENDERS }, allow_blank: true
  validates :password, presence: true, on: :create, if: -> { role == 'admin' || role == 'manager' }
  
  scope :active, -> { where(is_active: true) }

  has_many :orders, dependent: :nullify
  has_many :user_delivery_addresses, dependent: :destroy
  has_many :user_pickup_points, dependent: :destroy
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
  def full_name
    [last_name, first_name, middle_name].compact_blank.join(' ').presence || username
  end

  def first_name_display
    first_name.presence || username.split(' ').first || username
  end
  
  def last_name_display
    last_name.presence || username.split(' ').last || ''
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

  def self.normalize_gender(value)
    return nil if value.blank?

    str = value.to_s.strip
    return str if CANONICAL_GENDERS.include?(str)

    GENDER_ALIASES[str.downcase]
  end

  def gender
    self.class.normalize_gender(self[:gender]) || self[:gender]
  end

  def gender=(value)
    normalized = self.class.normalize_gender(value)
    super(normalized.nil? && value.present? ? value.to_s.strip : normalized)
  end

  after_commit :sync_with_crm, on: [:create, :update], if: :should_sync_crm?

  private

  def should_sync_crm?
    # Синхронизируем только при создании или изменении важных полей
    # Исключаем технические поля типа remember_token или last_login
    saved_change_to_username? || saved_change_to_email? || saved_change_to_phone? || 
    saved_change_to_first_name? || saved_change_to_last_name? || saved_change_to_middle_name? ||
    saved_change_to_encrypted_passport_json? || saved_change_to_gdpr_consent? || 
    saved_change_to_newsletter_consent? || saved_change_to_telegram_marketing? ||
    saved_change_to_email_marketing?
  end

  def sync_with_crm
    CrmSyncJob.perform_later('User', id)
  end
end
