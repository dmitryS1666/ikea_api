class ProductRecommendationSetting < ApplicationRecord
  enum placement: { cart: 1 }
  enum source_type: { sku_list: 0, product_list: 1, category: 2 }

  attr_accessor :product_skus_input

  validates :placement, presence: true, inclusion: { in: placements.keys }
  validates :source_type, presence: true
  validates :category_id, presence: true, if: :category?
  validate :validate_product_skus_presence

  before_validation :normalize_configuration
  before_validation :ensure_cart_placement

  scope :active, -> { where(active: true) }

  def self.instance
    cart.first_or_create! do |setting|
      setting.source_type = :sku_list
      setting.active = true
    end
  end

  def product_skus_input
    return @product_skus_input if instance_variable_defined?(:@product_skus_input)

    Array(product_skus).join("\n")
  end

  private

  def ensure_cart_placement
    self.placement = :cart
  end

  def normalize_configuration
    self.product_skus = normalize_skus(product_skus)

    if sku_list?
      self.product_skus = normalize_skus(product_skus_input)
      self.category_id = nil
    elsif product_list?
      self.product_skus = normalize_skus(product_skus)
      self.category_id = nil
    elsif category?
      self.category_id = category_id.to_s.strip.presence
      self.product_skus = []
    end
  end

  def normalize_skus(value)
    case value
    when nil
      []
    when Array
      value
    else
      value.to_s.split(/[\n,;]+/)
    end.map { |item| item.to_s.strip }.reject(&:blank?).uniq
  end

  def validate_product_skus_presence
    return if category?
    return if Array(product_skus).any?

    errors.add(:product_skus, "не могут быть пустыми")
  end
end
