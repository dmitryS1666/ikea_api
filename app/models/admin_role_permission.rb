# frozen_string_literal: true

class AdminRolePermission < ApplicationRecord
  EDITABLE_ROLES = User::ADMIN_PANEL_ROLES.freeze

  validates :role, presence: true, uniqueness: true, inclusion: { in: EDITABLE_ROLES }
  validate :permissions_must_be_known_keys

  before_validation :normalize_permissions!

  ROLE_ORDER_SQL = EDITABLE_ROLES.each_with_index.map { |role, index| "WHEN '#{role}' THEN #{index}" }.join(" ").freeze
  scope :ordered, -> { order(Arel.sql("CASE role #{ROLE_ORDER_SQL} ELSE 999 END")) }

  def self.ensure_defaults!
    EDITABLE_ROLES.each do |role|
      find_or_create_by!(role: role) do |record|
        record.permissions = default_permissions_for(role)
      end
    end
  end

  def self.permissions_for(role)
    key = role.to_s
    record = find_by(role: key)
    return normalize_hash(record.permissions) if record

    default_permissions_for(key)
  end

  def self.default_permissions_for(role)
    normalize_hash(
      User::BASE_ADMIN_PERMISSIONS.fetch(role.to_s, User::BASE_ADMIN_PERMISSIONS.fetch("user"))
    )
  end

  def self.role_label(role)
    User::ROLE_OPTIONS.key(role.to_s) || role.to_s.humanize
  end

  def self.normalize_hash(raw)
    source = raw.is_a?(Hash) ? raw : {}
    User::ADMIN_PERMISSION_KEYS.index_with do |key|
      value = if source.key?(key)
                source[key]
              elsif source.key?(key.to_s)
                source[key.to_s]
              else
                false
              end
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end

  def permissions_hash
    self.class.normalize_hash(permissions)
  end

  def role_label
    self.class.role_label(role)
  end

  def reset_to_defaults!
    update!(permissions: self.class.default_permissions_for(role))
  end

  User::ADMIN_PERMISSION_KEYS.each do |permission_key|
    define_method("permission_#{permission_key}") do
      permissions_hash[permission_key]
    end

    define_method("permission_#{permission_key}=") do |value|
      updated = permissions_hash
      updated[permission_key] = ActiveModel::Type::Boolean.new.cast(value)
      self.permissions = updated.transform_keys(&:to_s)
    end
  end

  private

  def normalize_permissions!
    self.permissions = permissions_hash.transform_keys(&:to_s)
  end

  def permissions_must_be_known_keys
    return if permissions.blank?
    return unless permissions.is_a?(Hash)

    unknown = permissions.keys.map(&:to_sym) - User::ADMIN_PERMISSION_KEYS
    errors.add(:permissions, "содержит неизвестные ключи: #{unknown.join(', ')}") if unknown.any?
  end
end
