class UserDeliveryAddress < ApplicationRecord
  ELEVATOR_TYPE_OPTIONS = [
    ["Пассажирский", "passenger"],
    ["Грузовой", "cargo"]
  ].freeze

  ELEVATOR_TYPE_LABELS = ELEVATOR_TYPE_OPTIONS.to_h { |label, value| [value, label] }.freeze

  belongs_to :user

  scope :alive, -> { where(deleted_at: nil) }

  enum :elevator_type, { passenger: "passenger", cargo: "cargo" }, validate: { allow_nil: true }

  before_validation :normalize_private_house_fields

  validates :city, presence: { message: "Укажите город" }
  validates :street, presence: { message: "Укажите улицу" }
  validates :house, presence: { message: "Укажите номер дома" }

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

  def elevator_type_label
    ELEVATOR_TYPE_LABELS[elevator_type]
  end

  private

  def normalize_private_house_fields
    return unless is_private_house?

    self.apartment = nil
    self.entrance = nil
    self.floor = nil
    self.elevator_type = nil
    self.intercom = nil
  end
end
