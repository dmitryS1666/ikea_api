class ReturnRequest < ApplicationRecord
  STATUSES = %w[new in_review approved rejected completed].freeze
  COMPENSATION_TYPES = %w[refund exchange].freeze

  belongs_to :user, optional: true
  belongs_to :order

  has_many_attached :attachments

  validates :reason, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :compensation_type, inclusion: { in: COMPENSATION_TYPES }, allow_blank: true
  validates :order_number, presence: true, on: :create, if: -> { first_name.present? || phone.present? }

  scope :ordered, -> { order(created_at: :desc) }

  def applicant_full_name
    [first_name, patronymic].compact.join(" ").strip.presence
  end

  after_create_commit :sync_with_crm

  private

  def sync_with_crm
    CrmSyncJob.perform_later('ReturnRequest', id)
  end
end
