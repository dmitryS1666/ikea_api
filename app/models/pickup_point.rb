class PickupPoint < ApplicationRecord
  PROVIDERS = %w[ikea europost].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(priority: :desc, provider: :asc, name: :asc) }
end
