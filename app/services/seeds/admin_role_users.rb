# frozen_string_literal: true

module Seeds
  class AdminRoleUsers
    USERS = [
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
      user = User.find_or_initialize_by(username: attributes.fetch(:username))
      password = environment["#{key}_PASSWORD"].presence

      if user.new_record? && production && password.blank?
        return { username: user.username, status: :skipped, error: "#{key}_PASSWORD is required" }
      end

      user.assign_attributes(
        first_name: attributes.fetch(:first_name),
        email: environment["#{key}_EMAIL"].presence || "#{attributes.fetch(:username)}@ikea_api.local",
        phone: environment["#{key}_PHONE"].presence || attributes.fetch(:phone),
        role: attributes.fetch(:role),
        is_active: true
      )

      # Повторный db:seed не меняет существующий пароль без явного ENV.
      password ||= "ChangeMe_#{key.downcase}_123" if user.new_record? && !production
      if password.present?
        user.password = password
        user.password_confirmation = password
      end

      user.save!
      { username: user.username, role: user.role, status: :saved }
    rescue ActiveRecord::RecordInvalid => e
      { username: attributes.fetch(:username), status: :failed, error: e.record.errors.full_messages.join(", ") }
    end
    private_class_method :upsert_user
  end
end
