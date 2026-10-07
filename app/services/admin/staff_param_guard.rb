# frozen_string_literal: true

module Admin
  # Серверное сужение полей админских форм. Кнопки в интерфейсе этому не замена.
  class StaffParamGuard
    REQUEST_RESOURCES = %w[orders return_requests cooperation_requests].freeze
    MANAGER_FIELDS = %w[status].freeze

    def self.apply(controller)
      # current_user is protected in trestle-auth — try/public_send cannot see it.
      user = controller.send(:current_user) if controller.respond_to?(:current_user, true)
      return unless user

      admin = controller.try(:admin)
      resource = (admin.try(:admin_name) || admin.try(:name)).to_s
      return unless %w[create update].include?(controller.action_name.to_s)

      payload = controller.params[resource.singularize]
      return unless payload.respond_to?(:delete)

      restrict_manager_request!(payload) if user.manager? && REQUEST_RESOURCES.include?(resource)
      keep_existing_phone!(payload) if user.site_admin?
      strip_passport!(payload) unless user.can_view_passport_data?
      strip_super_admin_role!(payload) if resource == "users" && !user.super_admin?
    end

    def self.restrict_manager_request!(payload)
      payload.keys.each do |key|
        payload.delete(key) unless MANAGER_FIELDS.include?(key.to_s)
      end
    end

    def self.keep_existing_phone!(payload)
      return unless payload.key?("phone") || payload.key?(:phone)

      phone = payload["phone"] || payload[:phone]
      return if phone.present?

      payload.delete("phone")
      payload.delete(:phone)
    end

    def self.strip_passport!(payload)
      %w[encrypted_passport_json passport_verified_at].each do |field|
        payload.delete(field)
        payload.delete(field.to_sym)
      end
    end

    def self.strip_super_admin_role!(payload)
      role = (payload["role"] || payload[:role]).to_s
      return unless role == "super_admin"

      payload.delete("role")
      payload.delete(:role)
    end

    private_class_method :restrict_manager_request!, :keep_existing_phone!, :strip_passport!, :strip_super_admin_role!
  end
end
