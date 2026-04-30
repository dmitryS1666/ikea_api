class OrderStatusEvent < ApplicationRecord
  belongs_to :order

  validates :to_status, presence: true
  validates :changed_at, presence: true
  validates :source, presence: true

  scope :ordered, -> { order(changed_at: :asc, id: :asc) }
end
