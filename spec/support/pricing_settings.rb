# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:each) do
    CalculatorSetting.ensure_defaults
  end
end
