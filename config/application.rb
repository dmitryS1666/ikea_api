require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
    # require "action_mailer/railtie"
    require "action_mailer/railtie"
    # require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "sprockets/railtie"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Загружаем переменные окружения из .env файла (только в development и test)
if defined?(Dotenv)
  Dotenv.load
end

module IkeaApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:en, :ru]
    config.time_zone = "Minsk" # Or whatever is appropriate for this project, let's stick to locale first

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    # ВАЖНО: api_only = false для поддержки ActiveAdmin
    # API-only функциональность обеспечивается через namespace :api в routes
    config.api_only = false
    
    # Для ActiveAdmin нужны helpers и views
    config.force_ssl = false
    config.action_controller.include_all_helpers = true
    
    # Добавляем middleware для сессий (нужно для Swagger авторизации)
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, 
      key: '_ikea_api_session',
      secret: Rails.application.credentials.secret_key_base || ENV['SECRET_KEY_BASE'] || 'development_secret_key_change_in_production',
      same_site: :lax,
      # В production отключаем secure, т.к. используем HTTP через kamal-proxy
      # SSL будет настроен на уровне proxy при привязке домена
      secure: Rails.env.production? && ENV['FORCE_SSL_COOKIES'] == 'true'
    config.middleware.use ActionDispatch::Flash
    
    # Redis для кэширования
    config.cache_store = :redis_cache_store, {
      url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
      password: ENV['REDIS_PASSWORD'],
      namespace: 'ikea_api',
      expires_in: 1.hour
    }

    # Переносим маршруты ActiveStorage под префикс /admin, который уже проброшен в NPM
    config.active_storage.routes_prefix = '/admin/storage'

    # Разрешаем отображение SVG в браузере вместо скачивания
    config.active_storage.content_types_to_serve_as_binary -= ['image/svg+xml']
    config.active_storage.content_types_allowed_inline += ['image/svg+xml']

    # Добавляем пути к шрифтам Font Awesome 6
    config.assets.paths << Rails.root.join("vendor", "assets", "fontawesome")

    # Active Record Encryption Configuration
    # NOTE: In production, these should be moved to credentials or environment variables.
    # These defaults are here to prevent application crashes when encryption is used.
    config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'] || "test_primary_key_must_be_32_chars_long_123"
    config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY'] || "test_deterministic_key_must_be_32_chars_long"
    config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'] || "test_salt"
  end
end
