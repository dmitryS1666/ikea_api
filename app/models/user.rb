class User < ApplicationRecord
  include Trestle::Auth::ModelMethods
  include Trestle::Auth::ModelMethods::Rememberable

  CANONICAL_GENDERS = %w[Male Female].freeze
  ROLE_ALIASES = {
    "manager" => "manager_requests"
  }.freeze
  ROLE_OPTIONS = {
    "Владелец / директор" => "admin",
    "Администратор сайта" => "site_admin",
    "Менеджер по заявкам" => "manager_requests",
    "Контент-менеджер" => "content_manager",
    "Бухгалтер / финансовый сотрудник" => "accountant",
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
    destructive_manage
    data_export
    view_personal_data
    customer_data_read
    customer_data_manage
    content_read
    content_manage
    orders_read
    orders_manage
    requests_read
    requests_manage
    finance_view
    finance_manage
    audit_view
    reports_view
    technical_read
    technical_manage
  ].freeze
  ADMIN_RESOURCE_RULES = {
    "dashboard" => { read: :reports_view, write: :reports_view },
    "users" => { read: :manage_users, write: :manage_users },
    "orders" => { read: :orders_read, write: :orders_manage },
    "return_requests" => { read: :requests_read, write: :requests_manage },
    "cooperation_requests" => { read: :requests_read, write: :requests_manage },
    "user_delivery_addresses" => { read: :customer_data_read, write: :customer_data_manage },
    "phone_verification_requests" => { read: :customer_data_read, write: :customer_data_manage },
    "consent_records" => { read: :customer_data_read, write: :customer_data_manage },
    "favorites" => { read: :customer_data_read, write: :customer_data_manage },
    "reviews" => { read: :customer_data_read, write: :customer_data_manage },
    "products" => { read: :content_read, write: :content_manage },
    "categories" => { read: :content_read, write: :content_manage },
    "breadcrumb_rules" => { read: :content_read, write: :content_manage },
    "featured_product_tabs" => { read: :content_read, write: :content_manage },
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
    "popular_search_queries" => { read: :reports_view, write: :content_manage },
    "exchange_rates" => { read: :finance_view, write: :finance_manage },
    "price_calculator" => { read: :finance_view, write: :finance_manage },
    "finance_entries" => { read: :finance_view, write: :finance_manage },
    "admin_audit_logs" => { read: :audit_view, write: :audit_view },
    "parser_control" => { read: :technical_read, write: :technical_manage },
    "cron_schedules" => { read: :technical_read, write: :technical_manage },
    "phone_auth_setting" => { read: :technical_read, write: :technical_manage },
    "calculator_setting" => { read: :technical_read, write: :technical_manage },
    "feed_setting" => { read: :technical_read, write: :technical_manage },
    "customs_duty_calculator" => { read: :finance_view, write: :finance_manage },
    "review_settings" => { read: :technical_read, write: :technical_manage },
    "europost_tester" => { read: :technical_read, write: :technical_manage },
    "auth/account" => { read: :reports_view, write: :reports_view }
  }.freeze
  ADMIN_READ_ACTIONS = %w[index show stats search by_category].freeze
  ADMIN_DESTRUCTIVE_ACTIONS = %w[
    destroy
    delete_photo
    remove_product
    remove_products
    reassign_products
    soft_delete
  ].freeze
  # Единственная точка регистрации выгрузок админки. Ключ — Trestle resource,
  # значения — action names. Новый export-action обязательно добавляется сюда.
  ADMIN_EXPORT_ACTIONS = {
    "products" => %w[
      build_products_xlsx
      reset_products_xlsx_export
      download_products_xlsx
      export_extended_attrs_input
    ].freeze,
    "finance_entries" => %w[export_registry].freeze,
    "users" => %w[export_marketing_emails].freeze
  }.freeze
  ADMIN_EXPORT_ACTION_PATTERN = /export|download|xlsx/i
  ADMIN_LANDING_RESOURCES = {
    "manager_requests" => "orders",
    "content_manager" => "products",
    "accountant" => "finance_entries",
    "technician" => "parser_control"
  }.freeze
  BASE_ADMIN_PERMISSIONS = {
    "admin" => ADMIN_PERMISSION_KEYS.index_with(true),
    "site_admin" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: false,
      view_personal_data: true,
      customer_data_read: true,
      customer_data_manage: true,
      content_read: true,
      content_manage: true,
      orders_read: true,
      orders_manage: true,
      requests_read: true,
      requests_manage: true,
      finance_view: false,
      finance_manage: false,
      audit_view: false,
      reports_view: true,
      technical_read: false,
      technical_manage: false
    },
    "manager_requests" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: false,
      view_personal_data: true,
      customer_data_read: false,
      customer_data_manage: false,
      content_read: false,
      content_manage: false,
      orders_read: true,
      orders_manage: true,
      requests_read: true,
      requests_manage: true,
      finance_view: false,
      finance_manage: false,
      audit_view: false,
      reports_view: false,
      technical_read: false,
      technical_manage: false
    },
    "content_manager" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: false,
      view_personal_data: false,
      customer_data_read: false,
      customer_data_manage: false,
      content_read: true,
      content_manage: true,
      orders_read: false,
      orders_manage: false,
      requests_read: false,
      requests_manage: false,
      finance_view: false,
      finance_manage: false,
      audit_view: false,
      reports_view: false,
      technical_read: false,
      technical_manage: false
    },
    "accountant" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: true,
      view_personal_data: true,
      customer_data_read: false,
      customer_data_manage: false,
      content_read: false,
      content_manage: false,
      orders_read: true,
      orders_manage: false,
      requests_read: false,
      requests_manage: false,
      finance_view: true,
      finance_manage: false,
      audit_view: false,
      reports_view: true,
      technical_read: false,
      technical_manage: false
    },
    "technician" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: false,
      view_personal_data: false,
      customer_data_read: false,
      customer_data_manage: false,
      content_read: false,
      content_manage: false,
      orders_read: false,
      orders_manage: false,
      requests_read: false,
      requests_manage: false,
      finance_view: false,
      finance_manage: false,
      audit_view: false,
      reports_view: false,
      technical_read: true,
      technical_manage: true
    },
    "observer" => {
      manage_users: false,
      restrictions_manage: false,
      destructive_manage: false,
      data_export: false,
      view_personal_data: false,
      customer_data_read: false,
      customer_data_manage: false,
      content_read: false,
      content_manage: false,
      orders_read: true,
      orders_manage: false,
      requests_read: true,
      requests_manage: false,
      finance_view: false,
      finance_manage: false,
      audit_view: false,
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
  # Получатели коммерческой email-рассылки:
  # email указан + подтверждён + согласие на маркетинг.
  # (отписавшиеся через unsubscribe получают оба флага согласия false).
  scope :marketing_email_recipients, lambda {
    where.not(email: [nil, ""])
         .where.not(email_verified_at: nil)
         .where("email_marketing IS TRUE OR newsletter_consent IS TRUE")
  }

  # Сначала удаляем заявки/отзывы, затем заказы с их историей статусов.
  has_many :return_requests, dependent: :destroy
  has_many :reviews, dependent: :destroy
  has_many :review_helpful_votes, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :assigned_orders, class_name: "Order", foreign_key: :assigned_to_id, dependent: :nullify, inverse_of: :assigned_to
  has_many :assigned_return_requests, class_name: "ReturnRequest", foreign_key: :assigned_to_id, dependent: :nullify, inverse_of: :assigned_to
  has_many :assigned_cooperation_requests, class_name: "CooperationRequest", foreign_key: :assigned_to_id, dependent: :nullify, inverse_of: :assigned_to
  has_many :user_delivery_addresses, dependent: :destroy
  has_many :user_pickup_points, dependent: :destroy
  has_many :search_query_logs, foreign_key: :customer_id, dependent: :nullify, inverse_of: :customer
  # У пользователя в БД может быть несколько корзин/избранных (нет unique на user_id),
  # поэтому удаляем все через has_many; has_one оставляем для API (favorite/cart).
  has_many :carts, dependent: :destroy
  has_one :cart
  has_many :favorites, dependent: :destroy
  has_one :favorite
  has_many :consent_records, dependent: :destroy
  has_many :email_verification_tokens, dependent: :destroy
  
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

  def admin_landing_resource
    ADMIN_LANDING_RESOURCES.fetch(role, "dashboard")
  end

  def allowed_for_admin_resource?(resource_name, action_name)
    return false unless can_access_admin_panel?
    return true if admin?

    resource_key = normalize_admin_resource_name(resource_name)
    return true if resource_key == "auth/account"

    rules = ADMIN_RESOURCE_RULES[resource_key]
    return false unless rules

    action = action_name.to_s
    if ADMIN_DESTRUCTIVE_ACTIONS.include?(action)
      return false unless has_admin_permission?(:destructive_manage)
    end

    registered_export = ADMIN_EXPORT_ACTIONS.fetch(resource_key, []).include?(action)
    return false if action.match?(ADMIN_EXPORT_ACTION_PATTERN) && !registered_export

    if registered_export
      return false unless has_admin_permission?(:data_export)
      return has_admin_permission?(rules[:read])
    end

    permission = if ADMIN_READ_ACTIONS.include?(action)
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
      destructive_manage: "Удаление данных",
      data_export: "Скачивание и экспорт данных",
      view_personal_data: "Доступ к персональным данным",
      customer_data_read: "Просмотр клиентских данных",
      customer_data_manage: "Изменение клиентских данных",
      content_read: "Просмотр контента",
      content_manage: "Редактирование контента",
      orders_read: "Просмотр заявок/заказов",
      orders_manage: "Обработка заявок/заказов",
      requests_read: "Просмотр возвратов и обращений",
      requests_manage: "Обработка возвратов и обращений",
      finance_view: "Доступ к финансовым данным",
      finance_manage: "Изменение финансовых настроек",
      audit_view: "Просмотр журнала действий администраторов",
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

  # Полный стоп любых писем на этот адрес (после отписки с неподтверждённого email).
  def email_suppressed?
    email_suppressed_at.present?
  end

  # Можно слать любые письма (транзакционные/сервисные).
  # После отписки без верификации — нельзя.
  def accepts_email?
    email.present? && !email_suppressed?
  end

  # Виртуальный флаг верификации для админки (в блоке флагов рассылок).
  def email_verified_flag
    email_verified?
  end

  alias email_verified_flag? email_verified_flag

  def email_verified_flag=(value)
    if ActiveModel::Type::Boolean.new.cast(value)
      self.email_verified_at ||= Time.current
      self.email_suppressed_at = nil
    else
      self.email_verified_at = nil
    end
  end

  def email_suppressed_flag
    email_suppressed?
  end

  alias email_suppressed_flag? email_suppressed_flag

  def email_suppressed_flag=(value)
    if ActiveModel::Type::Boolean.new.cast(value)
      self.email_suppressed_at ||= Time.current
    else
      self.email_suppressed_at = nil
    end
  end

  # Единый виртуальный переключатель для админки. newsletter_consent остаётся
  # legacy-полем, поэтому при ручном изменении email-рассылки обновляем оба
  # флага и не допускаем противоречивого состояния.
  def email_marketing_enabled
    email_marketing == true || newsletter_consent == true
  end

  alias email_marketing_enabled? email_marketing_enabled

  def email_marketing_enabled=(value)
    enabled = ActiveModel::Type::Boolean.new.cast(value)
    self.email_marketing = enabled
    self.newsletter_consent = enabled
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

  before_save :clear_email_verification_if_email_changed
  after_commit :sync_with_crm, on: [:create, :update], if: :should_sync_crm?
  after_commit :sync_marketing_subscription, on: [:create, :update], if: :should_sync_marketing_subscription?

  private

  # Смена email сбрасывает верификацию, кроме случая verify!,
  # где email и email_verified_at выставляются вместе.
  # Новый адрес снова может получать письма (снимаем suppress).
  def clear_email_verification_if_email_changed
    return unless will_save_change_to_email?
    return if will_save_change_to_email_verified_at? && email_verified_at.present?

    self.email_verified_at = nil
    self.email_suppressed_at = nil unless will_save_change_to_email_suppressed_at?
  end

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

    saved_change_to_email_marketing? ||
      saved_change_to_newsletter_consent? ||
      saved_change_to_email? ||
      saved_change_to_email_verified_at?
  end

  def sync_with_crm
    CrmSyncJob.perform_later('User', id)
  end

  def sync_marketing_subscription
    MarketingSubscriptionService.sync_user!(self)
  end
end
