# frozen_string_literal: true

module CheckoutConsentsHelpers
  def checkout_consents(overrides = {})
    {
      personal_data_consent: true,
      offer_agreement_consent: true,
      customs_broker_consent: true
    }.merge(overrides)
  end
end

RSpec.configure do |config|
  config.include CheckoutConsentsHelpers, type: :request
end
