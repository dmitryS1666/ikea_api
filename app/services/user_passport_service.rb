class UserPassportService
  # Encrypt/decrypt passport data using app secret.
  # NOTE: This is local storage only. CRM integration is intentionally skipped.

  def self.write!(user:, passport_hash:)
    # Validate passport number (relaxed format) if present
    number = passport_hash['passport_number'] || passport_hash[:passport_number] || passport_hash['number'] || passport_hash[:number]
    PassportNumberValidator.validate!(number) if number.present?

    user.update!(encrypted_passport_json: passport_hash.to_json)
  end

  def self.read(user)
    user.passport_data
  end

  def self.same?(a, b)
    return true if a.blank? && b.blank?
    return false if a.blank? ^ b.blank?
    normalize(a) == normalize(b)
  end

  def self.normalize(hash)
    hash.deep_stringify_keys.transform_values do |v|
      v.is_a?(String) ? v.strip : v
    end
  end
  private_class_method :normalize
end
