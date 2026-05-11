class PhoneAuthSetting < ApplicationRecord
  STATIC_TEST_CODE = '5806'.freeze

  def self.instance
    # Safe default: do not hit external Asterisk service unless explicitly enabled.
    first_or_create!(asterisk_enabled: false)
  end

  def self.asterisk_enabled?
    instance.asterisk_enabled?
  end
end
