class RecommendedProduct < ApplicationRecord
  validates :product_sku, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(position: :asc) }

  def product
    @product ||= Product.find_by(sku: product_sku)
  end
end
