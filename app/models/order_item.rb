class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product, primary_key: :sku, foreign_key: :product_sku, optional: true

  validates :product_sku, presence: true
  validates :quantity, presence: true, numericality: { only_integer: true, greater_than: 0 }

  before_validation :snapshot_image_url, on: :create
  before_validation :snapshot_email_content, on: :create

  def capture_email_snapshot!(force: false)
    product_record = product || Product.find_by(sku: product_sku)
    attrs = {}

    if force || name_snapshot.blank?
      attrs[:name_snapshot] = snapshot_name(product_record)
    end
    if force || description_snapshot.blank?
      attrs[:description_snapshot] = snapshot_description(product_record)
    end

    return self if attrs.empty?

    persisted? ? update_columns(attrs) : assign_attributes(attrs)
    self
  end

  private

  def snapshot_image_url
    return if image_url.present? || product_sku.blank?

    product_record = product || Product.find_by(sku: product_sku)
    self.image_url = OrderItemImageSnapshot.for_product(product_record)
  end

  def snapshot_email_content
    capture_email_snapshot!
  end

  def snapshot_name(product_record)
    product_record&.small_desc_name.presence ||
      product_record&.name_ru.presence ||
      product_record&.name.presence ||
      product_sku
  end

  def snapshot_description(product_record)
    product_record&.dimensions_ru.presence || product_record&.dimensions.presence || ""
  end
end
