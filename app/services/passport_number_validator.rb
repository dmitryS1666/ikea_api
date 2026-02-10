# frozen_string_literal: true
# Belarus passport number (relaxed): only validates letter/number counts.
# Format: 2 letters + 7 digits (e.g., MP1234567). We do NOT validate specific series letters.
class PassportNumberValidator
  FORMAT = /\A\p{L}{2}\d{7}\z/u

  def self.normalize(value)
    value.to_s.strip.gsub(/\s+/, '').upcase
  end

  def self.valid?(value)
    v = normalize(value)
    return false if v.blank?
    FORMAT.match?(v)
  end

  def self.validate!(value)
    return if valid?(value)
    raise ArgumentError, 'Номер паспорта должен быть в формате: 2 буквы и 7 цифр (например, MP1234567)'
  end
end
