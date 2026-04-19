class CooperationRequest < ApplicationRecord
  STATUSES = %w[new in_review contacted closed rejected].freeze

  validates :first_name, :last_name, :email, :phone, :city, :cooperation_type, :comment, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :personal_data_consent, acceptance: true
  validates :marketing_email_consent, inclusion: { in: [true, false] }

  scope :ordered, -> { order(created_at: :desc) }

  after_create_commit :sync_with_crm

  def full_name
    [first_name, last_name].compact.join(" ").strip
  end

  private

  def sync_with_crm
    CrmSyncJob.perform_later('CooperationRequest', id)
  end
end

