class UserPassportService
  # Encrypt/decrypt passport data using app secret.
  # NOTE: This is local storage only. CRM integration is intentionally skipped.

  def self.encryptor
    secret = Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret).generate_key('passport', 32)
    ActiveSupport::MessageEncryptor.new(key)
  end

  def self.write!(user:, passport_hash:)
    # Validate passport number (relaxed format) if present
    number = passport_hash['passport_number'] || passport_hash[:passport_number] || passport_hash['number'] || passport_hash[:number]
    PassportNumberValidator.validate!(number) if number.present?

    json = passport_hash.to_json
    user.update!(encrypted_passport_json: encryptor.encrypt_and_sign(json))
  end

  def self.read(user)
    return nil if user.encrypted_passport_json.blank?
    json = encryptor.decrypt_and_verify(user.encrypted_passport_json)
    JSON.parse(json)
  rescue StandardError
    nil
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
