class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product, primary_key: :sku, foreign_key: :product_sku, optional: true

  validates :product_sku, presence: true
  validates :quantity, presence: true, numericality: { only_integer: true, greater_than: 0 }

  before_validation :snapshot_image_url, on: :create

  private

  def snapshot_image_url
    return if image_url.present? || product_sku.blank?

    product_record = product || Product.find_by(sku: product_sku)
    self.image_url = OrderItemImageSnapshot.for_product(product_record)
  end
end
