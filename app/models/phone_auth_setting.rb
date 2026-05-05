class PhoneAuthSetting < ApplicationRecord
  STATIC_TEST_CODE = '5806'.freeze

  def self.instance
    first_or_create!
  end

  def self.asterisk_enabled?
    instance.asterisk_enabled?
  end
end
