class Product < ApplicationRecord
  # Валидации
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
  
  # Ассоциации
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true
  has_many :product_filter_values
  has_many :filter_values, through: :product_filter_values
  
  # Scopes
  scope :bestsellers, -> { where(is_bestseller: true) }
  scope :popular, -> { where(is_popular: true) }
  scope :with_category, -> { where.not(category_id: nil) }
  
  # Сериализация массивов
  serialize :variants, Array
  serialize :related_products, Array
  serialize :set_items, Array
  serialize :bundle_items, Array
  serialize :images, Array
  serialize :local_images, Array
  serialize :videos, Array
  serialize :manuals, Array
  
  # Callbacks
  before_save :calculate_delivery, if: :weight_changed?
  
  private
  
  def calculate_delivery
    # Логика расчета доставки
    # Аналогично deliveryService.js
  end
end
