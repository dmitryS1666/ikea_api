class UserDeliveryAddress < ApplicationRecord
  belongs_to :user

  scope :alive, -> { where(deleted_at: nil) }

  before_validation :normalize_private_house_fields

  validates :city, presence: true
  validates :street, presence: true
  validates :house, presence: true

  def formatted_address
    chunks = [
      city,
      street,
      house.present? ? "д. #{house}" : nil,
      building.present? ? "корп. #{building}" : nil,
      apartment.present? ? "кв. #{apartment}" : nil
    ].compact

    chunks.join(", ")
  end

  private

  def normalize_private_house_fields
    return unless is_private_house?

    self.apartment = nil
    self.entrance = nil
    self.floor = nil
    self.has_elevator = nil
    self.intercom = nil
  end
end
