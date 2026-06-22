class ConsentRecord < ApplicationRecord
  CONSENT_TYPES = %w[
    personal_data
    offer_agreement
    customs_broker
    newsletter_email
    newsletter_telegram
    gdpr
  ].freeze

  SOURCES = %w[
    registration
    checkout
    profile
    admin
    cooperation_form
    unsubscribe_webhook
  ].freeze

  belongs_to :user, optional: true
  belongs_to :order, optional: true

  validates :consent_type, presence: true, inclusion: { in: CONSENT_TYPES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :accepted, inclusion: { in: [true, false] }

  scope :ordered, -> { order(created_at: :desc) }
  scope :for_type, ->(type) { where(consent_type: type.to_s) }

  def legal_document_label
    return legal_page_slug if legal_page_slug.present?

    consent_type
  end
end
