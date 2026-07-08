class FeaturedProductTab < ApplicationRecord
  LIST_KEYS = %w[
    bestsellers
    popular
    recommended
    new_arrivals
    homepage_recommendations
  ].freeze

  LIST_KEY_LABELS = {
    "bestsellers" => "Хиты продаж",
    "popular" => "Популярные товары",
    "recommended" => "Рекомендованные товары",
    "new_arrivals" => "Новинки",
    "homepage_recommendations" => "Рекомендации на главной"
  }.freeze

  enum :list_key, LIST_KEYS.index_with(&:to_s)

  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true

  validates :list_key, presence: true
  validates :category_id, presence: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_product_skus_presence

  before_validation :normalize_fields

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }

  def product_skus_input
    Array(product_skus).join("\n")
  end

  def product_skus_input=(value)
    self.product_skus = normalize_skus(value)
  end

  def list_key_label
    LIST_KEY_LABELS[list_key.to_s] || list_key.to_s
  end

  private

  def normalize_fields
    self.category_id = category_id.to_s.strip.presence
    self.product_skus = normalize_skus(product_skus)
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
    return if Array(product_skus).any?

    errors.add(:product_skus, "не могут быть пустыми")
  end
end
