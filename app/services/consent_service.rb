class ConsentService
  CHECKOUT_CONSENT_FIELDS = {
    personal_data_consent: :personal_data,
    offer_agreement_consent: :offer_agreement,
    customs_broker_consent: :customs_broker
  }.freeze

  PROFILE_CONSENT_FIELDS = {
    gdpr_consent: :gdpr,
    newsletter_consent: :newsletter_email,
    email_marketing: :newsletter_email,
    telegram_marketing: :newsletter_telegram
  }.freeze

  CONSENT_ERROR_MESSAGES = {
    personal_data_consent: "Требуется согласие на обработку персональных данных",
    offer_agreement_consent: "Требуется согласие с публичной офертой",
    customs_broker_consent: "Требуется согласие с договором таможенного брокера"
  }.freeze

  def self.validate_checkout_consents!(params)
    CHECKOUT_CONSENT_FIELDS.each_key do |field|
      next if truthy?(params[field])

      return {
        error: CONSENT_ERROR_MESSAGES.fetch(field),
        code: "consent_required",
        field: field.to_s
      }
    end

    nil
  end

  def self.record_checkout_consents!(user:, order:, params:)
    CHECKOUT_CONSENT_FIELDS.each do |field, consent_type|
      next unless truthy?(params[field])

      record!(
        user: user,
        order: order,
        consent_type: consent_type,
        accepted: true,
        source: "checkout"
      )
    end

    order.update!(
      personal_data_consent: truthy?(params[:personal_data_consent]),
      offer_agreement_consent: truthy?(params[:offer_agreement_consent]),
      customs_broker_consent: truthy?(params[:customs_broker_consent])
    )

    if truthy?(params[:personal_data_consent])
      user.update!(
        personal_data_consent: true,
        personal_data_consented_at: Time.current
      )
    end
  end

  def self.record_registration_personal_data!(user:)
    record!(
      user: user,
      consent_type: :personal_data,
      accepted: true,
      source: "registration"
    )

    user.update!(
      personal_data_consent: true,
      personal_data_consented_at: Time.current
    )
  end

  def self.record_profile_consent_changes!(user:, previous_values:, new_values:)
    PROFILE_CONSENT_FIELDS.each do |field, consent_type|
      old_value = previous_values[field]
      new_value = new_values[field]
      next if new_value.nil? || old_value == new_value

      record!(
        user: user,
        consent_type: consent_type,
        accepted: truthy?(new_value),
        source: "profile",
        metadata: { field: field.to_s }
      )
    end
  end

  def self.record!(user:, consent_type:, accepted:, source:, order: nil, metadata: {})
    slug = LegalPage.consent_slug_for(consent_type)
    legal_page = slug.present? ? LegalPage.find_by(slug: slug) : nil

    ConsentRecord.create!(
      user: user,
      order: order,
      consent_type: consent_type.to_s,
      accepted: accepted,
      legal_page_slug: slug || legal_page&.slug,
      legal_page_version_at: legal_page&.updated_at,
      source: source,
      metadata: metadata
    )
  end

  def self.truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
