class UserPassportService
  # Encrypt/decrypt passport data using app secret.
  # NOTE: This is local storage only. CRM integration is intentionally skipped.
  PROFILE_FIELD_ALIASES = {
    "first_name" => ["first_name"],
    "last_name" => ["last_name"],
    "middle_name" => ["middle_name"],
    "dob" => ["dob", "birth_date", "date_of_birth", "birthday"]
  }.freeze

  def self.write!(user:, passport_hash:)
    validate_passport_number!(passport_hash)
    user.update!(encrypted_passport_json: passport_hash.to_json)
  end

  def self.validate_passport_number!(passport_hash)
    full_number = passport_full_number(passport_hash)
    PassportNumberValidator.validate!(full_number) if full_number.present?
  end

  def self.read(user)
    user.passport_data
  end

  def self.same?(a, b)
    return true if a.blank? && b.blank?
    return false if a.blank? ^ b.blank?
    normalize(a) == normalize(b)
  end

  def self.profile_attributes(passport_hash)
    hash = normalize(passport_hash)
    return {} if hash.blank?

    attrs = {}
    PROFILE_FIELD_ALIASES.each do |target_key, aliases|
      value = aliases.lazy.map { |key| hash[key] }.find(&:present?)
      attrs[target_key.to_sym] = value if value.present?
    end
    attrs
  end

  def self.with_profile_fields(user:, passport_hash:)
    hash = normalize(passport_hash)
    return nil if hash.blank?

    data = hash.dup
    user_profile = {
      "first_name" => user.first_name,
      "last_name" => user.last_name,
      "middle_name" => user.middle_name,
      "dob" => user.dob&.to_s
    }

    user_profile.each do |key, value|
      next if value.blank?
      data[key] = value
    end

    data
  end

  def self.passport_full_number(passport_hash)
    number = passport_hash['passport_number'] || passport_hash[:passport_number] || passport_hash['number'] || passport_hash[:number]
    series = passport_hash['series'] || passport_hash[:series]

    if series.present? && number.present? && !number.to_s.match?(/[a-zA-Z\u0400-\u04FF]/)
      "#{series}#{number}"
    else
      number
    end
  end
  private_class_method :passport_full_number

  def self.normalize(hash)
    hash.deep_stringify_keys.transform_values do |v|
      v.is_a?(String) ? v.strip : v
    end
  end
  private_class_method :normalize
end
