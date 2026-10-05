class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product, primary_key: :sku, foreign_key: :product_sku, optional: true

  validates :product_sku, presence: true
  validates :quantity, presence: true, numericality: { only_integer: true, greater_than: 0 }

  before_validation :snapshot_image_url, on: :create
  before_validation :snapshot_email_content, on: :create
  before_validation :snapshot_poland_content, on: :create

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

  # Full catalog title for CRM / display: "IKEA PS 2026 Стол, зеленый, 96 см".
  # Prefer live product (name + small_desc_name); fall back to frozen snapshot / SKU.
  def catalog_title
    product_record = product || Product.find_by(sku: product_sku)
    if product_record
      title = SeoHelper.record_full_name(product_record).to_s.strip
      return title if title.present?
    end

    name_snapshot.presence || product_sku.presence || "Товар"
  end

  # Heal missing ShopByShop snapshots from the current catalog.
  # Never overwrites an existing PLN/URL snapshot and never uses BYN OrderItem#price.
  # Returns true when any field was filled.
  def ensure_poland_snapshot!(persist: true)
    product_record = product || Product.find_by(sku: product_sku)
    attrs = {}

    if poland_price_pln.nil?
      catalog_price = product_record&.price
      if catalog_price.present? && catalog_price.to_f.finite? && catalog_price.to_f >= 1
        attrs[:poland_price_pln] = catalog_price
      end
    end

    if poland_product_url.blank?
      catalog_url = product_record&.url.to_s.strip
      attrs[:poland_product_url] = catalog_url if catalog_url.present?
    end

    if name_snapshot.blank?
      attrs[:name_snapshot] = snapshot_name(product_record)
    end

    return false if attrs.empty?

    if persist && persisted?
      update_columns(attrs.merge(updated_at: Time.current))
      assign_attributes(attrs)
    else
      assign_attributes(attrs)
    end
    true
  end

  private

  def snapshot_poland_content
    ensure_poland_snapshot!(persist: false)
  end

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
