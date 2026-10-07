# frozen_string_literal: true

module Seeds
  class AdminRoleUsers
    USERS = [
      { key: "SUPER_ADMIN", username: "super_admin", first_name: "Суперадминистратор", role: "super_admin", phone: "+375290000008" },
      { key: "DIRECTOR", username: "director", first_name: "Владимир", role: "admin", phone: "+375290000001" },
      { key: "SITE_ADMIN", username: "site_admin", first_name: "Администратор", role: "site_admin", phone: "+375290000002" },
      { key: "REQUEST_MANAGER", username: "requests_manager", first_name: "Менеджер", role: "manager_requests", phone: "+375290000003" },
      { key: "CONTENT_MANAGER", username: "content_manager", first_name: "Контент-менеджер", role: "content_manager", phone: "+375290000004" },
      { key: "ACCOUNTANT", username: "accountant", first_name: "Бухгалтер", role: "accountant", phone: "+375290000005" },
      { key: "TECHNICIAN", username: "technician", first_name: "Технический специалист", role: "technician", phone: "+375290000006" },
      { key: "OBSERVER", username: "observer", first_name: "Наблюдатель", role: "observer", phone: "+375290000007" }
    ].freeze

    def self.call(environment: ENV, production: Rails.env.production?)
      USERS.map { |attributes| upsert_user(attributes, environment:, production:) }
    end

    def self.upsert_user(attributes, environment:, production:)
      key = attributes.fetch(:key)
      username = attributes.fetch(:username)
      user = User.find_by(username: username)

      if user&.role == "user"
        return { username: username, status: :failed, error: "username belongs to a customer" }
      end

      # Повторный запуск не меняет пароль, роль, блокировку и ограничения.
      if user&.persisted?
        return { username: user.username, role: user.role, status: :saved }
      end

      password = environment["#{key}_PASSWORD"].presence
      if production && password.blank?
        return { username: username, status: :skipped, error: "#{key}_PASSWORD is required" }
      end

      password ||= SecureRandom.alphanumeric(24)
      user = User.new(
        username: username,
        first_name: attributes.fetch(:first_name),
        email: environment["#{key}_EMAIL"].presence || "#{username}@ikea_api.local",
        phone: environment["#{key}_PHONE"].presence || attributes.fetch(:phone),
        role: attributes.fetch(:role),
        is_active: true,
        password: password,
        password_confirmation: password
      )
      user.save!
      store_local_password(username, password) unless production || Rails.env.test?
      { username: user.username, role: user.role, status: :saved }
    rescue ActiveRecord::RecordInvalid => e
      { username: username, status: :failed, error: e.record.errors.full_messages.join(", ") }
    end

    def self.store_local_password(username, password)
      path = Rails.root.join("tmp/rbac_local_credentials.md")
      FileUtils.mkdir_p(path.dirname)
      created = !File.exist?(path)
      File.open(path, "a", 0o600) do |file|
        file.puts("# Local RBAC accounts") if created
        file.puts("- #{username}: #{password}")
      end
      File.chmod(0o600, path)
    end
    private_class_method :upsert_user, :store_local_password
  end
end
