class PickupPoint < ApplicationRecord
  has_many :user_pickup_points, dependent: :nullify

  scope :active, -> { where(active: true) }
  scope :europost, -> { where(provider: "europost") }
  scope :priority, -> { where(priority: true) }

  validates :provider, presence: true
  validates :name, presence: true
  validates :max_weight_kg, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :max_volume_m3, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
