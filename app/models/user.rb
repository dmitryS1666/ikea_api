class User < ApplicationRecord
  include Trestle::Auth::ModelMethods
  include Trestle::Auth::ModelMethods::Rememberable

  CANONICAL_GENDERS = %w[Male Female].freeze
  ROLE_ALIASES = {
    "manager" => "manager_requests"
  }.freeze
  ROLE_OPTIONS = {
    "Директор / Владелец" => "admin",
    "Администратор сайта" => "site_admin",
    "Менеджер по заявкам" => "manager_requests",
    "Контент-менеджер" => "content_manager",
    "Бухгалтер" => "accountant",
    "Технический специалист" => "technician",
    "Наблюдатель" => "observer",
    "Пользователь" => "user"
  }.freeze
  ADMIN_PANEL_ROLES = %w[
    admin
    site_admin
    manager_requests
    content_manager
    accountant
    technician
    observer
  ].freeze
  ADMIN_PERMISSION_KEYS = %i[
    manage_users
    restrictions_manage
    view_personal_data
    content_read
    content_manage
    orders_read
    orders_manage
    finance_view
    reports_view
    technical_read
    technical_manage
  ].freeze
  ADMIN_RESOURCE_RULES = {
    "dashboard" => { read: :reports_view, write: :reports_view },
    "users" => { read: :manage_users, write: :manage_users },
    "orders" => { read: :orders_read, write: :orders_manage },
    "return_requests" => { read: :orders_read, write: :orders_manage },
    "cooperation_requests" => { read: :orders_read, write: :orders_manage },
    "user_delivery_addresses" => { read: :orders_read, write: :orders_manage },
    "phone_verification_requests" => { read: :orders_read, write: :orders_manage },
    "consent_records" => { read: :orders_read, write: :orders_manage },
    "favorites" => { read: :orders_read, write: :orders_manage },
    "reviews" => { read: :orders_read, write: :orders_manage },
    "products" => { read: :content_read, write: :content_manage },
    "categories" => { read: :content_read, write: :content_manage },
    "home_banners" => { read: :content_read, write: :content_manage },
    "content_articles" => { read: :content_read, write: :content_manage },
    "legal_pages" => { read: :content_read, write: :content_manage },
    "seo_catalog_pages" => { read: :content_read, write: :content_manage },
    "global_seo_settings" => { read: :content_read, write: :content_manage },
    "product_recommendation_settings" => { read: :content_read, write: :content_manage },
    "promo_codes" => { read: :content_read, write: :content_manage },
    "promo_code_products" => { read: :content_read, write: :content_manage },
    "promo_code_categories" => { read: :content_read, write: :content_manage },
    "search_query_logs" => { read: :reports_view, write: :reports_view },
    "popular_search_queries" => { read: :reports_view, write: :reports_view },
    "exchange_rates" => { read: :finance_view, write: :technical_manage },
    "price_calculator" => { read: :finance_view, write: :technical_manage },
    "parser_control" => { read: :technical_read, write: :technical_manage },
    "cron_schedules" => { read: :technical_read, write: :technical_manage },
    "phone_auth_setting" => { read: :technical_read, write: :technical_manage },
    "calculator_setting" => { read: :technical_read, write: :technical_manage },
    "feed_setting" => { read: :technical_read, write: :technical_manage },
    "customs_duty_calculator" => { read: :technical_read, write: :technical_manage },
    "review_settings" => { read: :technical_read, write: :technical_manage },
    "europost_tester" => { read: :technical_read, write: :technical_manage },
    "auth/account" => { read: :reports_view, write: :reports_view }
  }.freeze
  ADMIN_READ_ACTIONS = %w[index show stats].freeze
  BASE_ADMIN_PERMISSIONS = {
    "admin" => ADMIN_PERMISSION_KEYS.index_with(true),
    "site_admin" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: true,
      content_read: true,
      content_manage: true,
      orders_read: true,
      orders_manage: true,
      finance_view: true,
      reports_view: true,
      technical_read: true,
      technical_manage: false
    },
    "manager_requests" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: true,
      content_read: false,
      content_manage: false,
      orders_read: true,
      orders_manage: true,
      finance_view: false,
      reports_view: true,
      technical_read: false,
      technical_manage: false
    },
    "content_manager" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: false,
      content_read: true,
      content_manage: true,
      orders_read: false,
      orders_manage: false,
      finance_view: false,
      reports_view: true,
      technical_read: false,
      technical_manage: false
    },
    "accountant" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: true,
      content_read: false,
      content_manage: false,
      orders_read: true,
      orders_manage: false,
      finance_view: true,
      reports_view: true,
      technical_read: true,
      technical_manage: false
    },
    "technician" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: false,
      content_read: false,
      content_manage: false,
      orders_read: false,
      orders_manage: false,
      finance_view: false,
      reports_view: true,
      technical_read: true,
      technical_manage: true
    },
    "observer" => {
      manage_users: false,
      restrictions_manage: false,
      view_personal_data: false,
      content_read: true,
      content_manage: false,
      orders_read: true,
      orders_manage: false,
      finance_view: true,
      reports_view: true,
      technical_read: false,
      technical_manage: false
    },
    "user" => ADMIN_PERMISSION_KEYS.index_with(false)
  }.freeze
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
  validates :role, inclusion: { in: ROLE_OPTIONS.values }
  validates :country_code, inclusion: { in: %w[RB РФ РК] }, allow_blank: true
  validates :gender, inclusion: { in: CANONICAL_GENDERS }, allow_blank: true
  validates :password, presence: true, on: :create, if: -> { can_access_admin_panel? }
  
  scope :active, -> { where(is_active: true) }

  has_many :orders, dependent: :nullify
  has_many :user_delivery_addresses, dependent: :destroy
  has_many :user_pickup_points, dependent: :destroy
  has_many :reviews, dependent: :destroy
  has_many :review_helpful_votes, dependent: :destroy
  has_many :search_query_logs, foreign_key: :customer_id, dependent: :nullify, inverse_of: :customer
  has_many :return_requests, dependent: :destroy
  has_one :cart, dependent: :destroy
  has_one :favorite, dependent: :destroy
  has_many :consent_records, dependent: :destroy
  
  def admin?
    role == 'admin'
  end
  
  def manager?
    role == 'manager_requests'
  end

  def can_access_admin_panel?
    is_active? && ADMIN_PANEL_ROLES.include?(role)
  end

  def custom_permissions_hash
    return {} unless custom_permissions.is_a?(Hash)

    custom_permissions
      .transform_keys(&:to_sym)
      .slice(*ADMIN_PERMISSION_KEYS)
      .transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) }
  end

  def permissions_for_admin
    base = BASE_ADMIN_PERMISSIONS.fetch(role, BASE_ADMIN_PERMISSIONS.fetch("user")).dup
    custom_permissions_hash.each { |key, value| base[key] = value }
    base
  end

  def has_admin_permission?(permission)
    permissions_for_admin[permission.to_sym] == true
  end

  def can_manage_users?
    has_admin_permission?(:manage_users)
  end

  def can_manage_restrictions?
    has_admin_permission?(:restrictions_manage)
  end

  def can_view_personal_data?
    has_admin_permission?(:view_personal_data)
  end

  def allowed_for_admin_resource?(resource_name, action_name)
    return false unless can_access_admin_panel?
    return true if admin?

    resource_key = normalize_admin_resource_name(resource_name)
    return true if resource_key == "auth/account"

    rules = ADMIN_RESOURCE_RULES[resource_key]
    return false unless rules

    permission = if ADMIN_READ_ACTIONS.include?(action_name.to_s)
                   rules[:read]
                 else
                   rules[:write]
                 end
    has_admin_permission?(permission)
  end

  before_validation :normalize_role!
  before_validation :sanitize_custom_permissions!

  def self.permission_label(permission_key)
    {
      manage_users: "Управление пользователями и ролями",
      restrictions_manage: "Настройка индивидуальных ограничений",
      view_personal_data: "Доступ к персональным данным",
      content_read: "Просмотр контента",
      content_manage: "Редактирование контента",
      orders_read: "Просмотр заявок/заказов",
      orders_manage: "Обработка заявок/заказов",
      finance_view: "Доступ к финансовым данным",
      reports_view: "Просмотр отчетов и дашборда",
      technical_read: "Просмотр технических настроек",
      technical_manage: "Изменение технических настроек"
    }.fetch(permission_key.to_sym, permission_key.to_s.humanize)
  end

  ADMIN_PERMISSION_KEYS.each do |permission_key|
    define_method("custom_permission_#{permission_key}") do
      custom_permissions_hash[permission_key]
    end

    define_method("custom_permission_#{permission_key}=") do |value|
      casted = ActiveModel::Type::Boolean.new.cast(value)
      updated = custom_permissions_hash
      updated[permission_key] = casted
      self.custom_permissions = updated
    end
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

  def email_verified?
    email_verified_at.present?
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
  after_commit :sync_marketing_subscription, on: [:create, :update], if: :should_sync_marketing_subscription?

  private

  def normalize_admin_resource_name(name)
    raw = name.to_s
    return raw if raw.include?("/")

    raw.split("::").last.to_s.underscore
  end

  def normalize_role!
    current = role.to_s.strip
    self.role = ROLE_ALIASES.fetch(current, current)
  end

  def sanitize_custom_permissions!
    self.custom_permissions = custom_permissions_hash
  end

  def should_sync_crm?
    # Синхронизируем только при создании или изменении важных полей
    # Исключаем технические поля типа remember_token или last_login
    saved_change_to_username? || saved_change_to_email? || saved_change_to_phone? || 
    saved_change_to_first_name? || saved_change_to_last_name? || saved_change_to_middle_name? ||
    saved_change_to_encrypted_passport_json? || saved_change_to_gdpr_consent? || 
    saved_change_to_personal_data_consent? ||
    saved_change_to_newsletter_consent? || saved_change_to_telegram_marketing? ||
    saved_change_to_email_marketing?
  end

  def should_sync_marketing_subscription?
    return false if email.blank?

    saved_change_to_email_marketing? || saved_change_to_newsletter_consent? || saved_change_to_email?
  end

  def sync_with_crm
    CrmSyncJob.perform_later('User', id)
  end

  def sync_marketing_subscription
    MarketingSubscriptionService.sync_user!(self)
  end
end
