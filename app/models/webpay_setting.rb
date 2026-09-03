# frozen_string_literal: true

class WebpaySetting < ApplicationRecord
  def self.instance
    first_or_create!(test_mode: true)
  end

  def self.test_mode?
    instance.test_mode?
  end

  def self.live_mode?
    !test_mode?
  end
end
