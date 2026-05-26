class UserPassportService
  # Encrypt/decrypt passport data using app secret.
  # NOTE: This is local storage only. CRM integration is intentionally skipped.

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
