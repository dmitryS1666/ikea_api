class Product < ApplicationRecord
  # Валидации
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true

  # Ассоциации
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true

  has_many :category_products, dependent: :destroy
  has_many :categories, through: :category_products, source: :category

  has_many :product_filter_values, dependent: :delete_all

  has_one :seo_meta, as: :seoable, class_name: 'SeoMetum', dependent: :destroy
  accepts_nested_attributes_for :seo_meta, allow_destroy: true, update_only: true

  def primary_category
    category || categories.order(:name).first
  end

  # Scopes
  scope :active, -> { all }
  scope :bestsellers, -> { where(is_bestseller: true) }
  scope :new_arrivals, -> { where(is_new: true) }
  scope :popular, -> { where(is_popular: true) }
  scope :recommended, -> { where(is_recommended: true) }
  scope :with_category, -> { where.not(category_id: nil) }
  scope :by_rating, -> { order(rating_weighted: :desc, rating_count: :desc) }

  # Сериализация массивов
  serialize :variants, coder: JSON
  serialize :related_products, coder: JSON
  serialize :set_items, coder: JSON
  serialize :bundle_items, coder: JSON
  serialize :included_products, coder: JSON
  serialize :images, coder: JSON
  serialize :local_images, coder: JSON
  serialize :videos, coder: JSON
  serialize :manuals, coder: JSON
  serialize :features, coder: JSON
  serialize :assembly_documents, coder: JSON

  before_save :cache_slug, if: -> { name_changed? || name_ru_changed? || cached_slug.blank? }

  def slug
    cached_slug || generate_slug
  end

  # Callbacks
  before_save :calculate_delivery, if: :weight_changed?
  after_commit :enqueue_filters_reindex, on: [:create, :update]

  private

  def cache_slug
    self.cached_slug = generate_slug
  end

  def generate_slug
    source = name_ru.presence || name.presence || sku
    SlugifyService.call(source)
  end

  def calculate_delivery
    # Логика расчета доставки
    # Аналогично deliveryService.js
  end

  def enqueue_filters_reindex
    return unless saved_change_to_full_attributes? ||
                  saved_change_to_price? ||
                  saved_change_to_rating_avg? ||
                  saved_change_to_rating_weighted? ||
                  saved_change_to_is_bestseller? ||
                  saved_change_to_is_new? ||
                  saved_change_to_is_popular? ||
                  saved_change_to_is_recommended? ||
                  saved_change_to_quantity? ||
                  saved_change_to_collection? ||
                  saved_change_to_features?

    category_ids = categories.pluck(:ikea_id)
    category_ids << category_id if category_id.present?
    category_ids = category_ids.compact.uniq
    return if category_ids.empty?

    ReindexProductFiltersJob.perform_later(id, category_ids)
  end
end
