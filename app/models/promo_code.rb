class PromoCode < ApplicationRecord
  has_many :promo_code_products, dependent: :destroy
  has_many :promo_code_categories, dependent: :destroy

  enum discount_type: { percent: 0, fixed_byn: 1 }

  validates :code, presence: true, uniqueness: true
  validates :discount_value, presence: true, numericality: { greater_than: 0 }

  before_validation :normalize_code

  def active_now?(time = Time.current)
    return false unless active
    return false if starts_at.present? && starts_at > time
    return false if ends_at.present? && ends_at < time

    true
  end

  scope :active_now, ->(time = Time.current) {
    where(active: true)
      .where('starts_at IS NULL OR starts_at <= ?', time)
      .where('ends_at IS NULL OR ends_at >= ?', time)
  }

  def self.for_sku(sku)
    active_now.to_a.select { |p| p.applies_to_sku?(sku) }
  end

  def expired?(time = Time.current)
    ends_at.present? && ends_at < time
  end

  def applies_to_sku?(sku, product_category_ids = nil)
    return true if promo_code_products.none? && promo_code_categories.none?

    return true if promo_code_products.where(product_sku: sku).exists?

    category_ids = if product_category_ids
                     product_category_ids
                   else
                     product = Product.find_by(sku: sku)
                     return false unless product
                     [product.category_id] + product.category_products.pluck(:category_id)
                   end

    promo_code_categories.where(category_id: category_ids.compact.uniq).exists?
  end

  private

  def normalize_code
    self.code = code.to_s.strip.upcase
  end
end
