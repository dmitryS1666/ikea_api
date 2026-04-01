# frozen_string_literal: true

class Category < ApplicationRecord
  self.primary_key = "ikea_id"

  attr_accessor :parent_ikea_id

  has_one_attached :icon
  has_one_attached :pictogram
  has_one_attached :background_image

  validates :ikea_id, presence: true, uniqueness: true
  validates :name, presence: true

  has_many :products, foreign_key: :category_id, primary_key: :ikea_id

  has_many :category_products, foreign_key: :category_id, primary_key: :ikea_id, dependent: :destroy
  has_many :products_through_categories, through: :category_products, source: :product
  has_many :product_filter_values, foreign_key: :category_id, primary_key: :ikea_id, dependent: :delete_all

  has_one :seo_meta, as: :seoable, class_name: "SeoMetum", dependent: :destroy
  accepts_nested_attributes_for :seo_meta, allow_destroy: true, update_only: true

  serialize :parent_ids, coder: JSON

  before_save :cache_slug, if: -> { name_changed? || translated_name_changed? || cached_slug.blank? }
  before_validation :assign_parent_ikea_id_from_parent_ids

  validate :parent_cannot_be_self
  validate :parent_cannot_be_descendant

  enum :default_sort, {
    popular: "popular",
    newest: "newest",
    cheapest: "cheapest",
    expensive: "expensive"
  }

  scope :with_numeric_id, -> { where("ikea_id ~ '^[0-9]+$'") }
  scope :top, -> { where(is_top: true).order(top_position: :asc) }
  scope :popular, -> { where(is_popular: true) }
  scope :custom, -> { where(is_custom: true) }
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }

  scope :top_level, -> {
    where(
      "is_important = ? OR parent_ids IS NULL OR parent_ids::text = ? OR parent_ids::text = ? OR parent_ids::text = ?",
      true, "[]", "\"\"", ""
    )
  }

  def slug
    cached_slug || generate_slug
  end

  def display_filters
    available_filters || []
  end

  # фильтры текущей категории + всех прямых дочерних
  def display_filters_with_children
    all_filters = normalize_filters(display_filters)
  
    direct_children.each do |child|
      all_filters.concat(normalize_filters(child.display_filters))
    end
  
    all_filters.uniq { |filter| filter["key"] || filter[:key] }
  end

  def current_parent_ikea_id
    ids = self.class.normalize_parent_ids(parent_ids)
    return nil if ids.blank?

    ids.last == ikea_id.to_s ? ids[-2] : ids.last
  end

  def descendant_ikea_ids
    return [] if ikea_id.blank?

    Category.where("parent_ids::text LIKE ?", "%#{ikea_id}%")
            .where.not(ikea_id: ikea_id.to_s)
            .pluck(:ikea_id)
            .map(&:to_s)
            .select do |candidate_id|
              category = Category.find_by(ikea_id: candidate_id)
              next false unless category

              self.class.normalize_parent_ids(category.parent_ids).include?(ikea_id.to_s)
            end
  end

  def children_count
    direct_children.count
  end

  # прямые дочерние категории
  def direct_children
    return [] unless ikea_id.present?
  
    Category.not_deleted
            .to_a
            .select { |category| self.class.direct_parent_id_for(category) == ikea_id.to_s }
            .sort_by { |category| category.translated_name.presence || category.name.to_s }
  end

  # если где-то в проекте уже используется children — можно оставить алиасом
  def children
    direct_children
  end

  def has_children?
    children_count > 0
  end

  def has_products?
    products.exists?
  end

  def numeric_id?
    ikea_id.to_s.match?(/^\d+$/)
  end

  def uuid_id?
    ikea_id.to_s.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  def root_level?
    current_parent_ikea_id.blank?
  end

  class << self
    def build_tree(categories, sort_roots_by_position: false)
      categories = Array(categories)
    
      grouped = categories.group_by { |c| c.ikea_id.to_s }
      categories = grouped.values.map(&:last)
    
      by_ikea_id = categories.index_by { |category| category.ikea_id.to_s }
      children_map = Hash.new { |h, k| h[k] = [] }
      roots = []
    
      categories.each do |category|
        direct_parent_id = direct_parent_id_for(category)
    
        node = {
          category: category,
          children: []
        }
    
        if direct_parent_id.present? && by_ikea_id.key?(direct_parent_id) && direct_parent_id != category.ikea_id.to_s
          children_map[direct_parent_id] << node
        else
          roots << node
        end
      end
    
      attach_children = lambda do |nodes, depth = 1, visited_ids = []|
        nodes.each do |node|
          ikea_id = node[:category].ikea_id.to_s
    
          if visited_ids.include?(ikea_id)
            Rails.logger.warn("Circular dependency detected for category #{ikea_id}")
            node[:children] = []
            next
          end
    
          children = children_map[ikea_id]
    
          # 2 уровень и глубже — по алфавиту
          children = sort_tree_nodes(children)
    
          node[:children] = children
    
          if node[:children].any?
            attach_children.call(node[:children], depth + 1, visited_ids + [ikea_id])
          end
        end
      end
    
      roots =
        if sort_roots_by_position
          sort_root_nodes(roots)
        else
          sort_tree_nodes(roots)
        end
    
      attach_children.call(roots)
      roots
    end
  
    def normalize_parent_ids(value)
      case value
      when nil
        []
      when Array
        value.compact.map(&:to_s).reject(&:blank?)
      else
        Array(value).compact.map(&:to_s).reject(&:blank?)
      end
    end
  
    def direct_parent_id_for(category)
      ids = normalize_parent_ids(category.parent_ids)
      return nil if ids.blank?
  
      ids.last == category.ikea_id.to_s ? ids[-2] : ids.last
    end
    
    def sort_root_nodes(nodes)
      nodes.sort_by do |node|
        category = node[:category]
        [
          category.root_position.to_i,
          (category.translated_name.presence || category.name).to_s.mb_chars.downcase.to_s
        ]
      end
    end

    private :sort_root_nodes
  
    private
  
    def sort_tree_nodes(nodes)
      nodes.sort_by do |node|
        category = node[:category]
        (category.translated_name.presence || category.name).to_s.mb_chars.downcase.to_s
      end
    end
  end

  private

  def normalize_filters(filters)
    Array(filters).compact.map do |filter|
      filter.is_a?(Hash) ? filter.deep_stringify_keys : filter
    end
  end

  def assign_parent_ikea_id_from_parent_ids
    self.parent_ikea_id = current_parent_ikea_id if parent_ikea_id.blank?
  end

  def parent_cannot_be_self
    return if parent_ikea_id.blank?
    return unless parent_ikea_id.to_s == ikea_id.to_s

    errors.add(:parent_ikea_id, "не может совпадать с текущей категорией")
  end

  def parent_cannot_be_descendant
    return if parent_ikea_id.blank?
    return if ikea_id.blank?

    if descendant_ikea_ids.include?(parent_ikea_id.to_s)
      errors.add(:parent_ikea_id, "не может быть дочерней категорией текущей категории")
    end
  end

  def cache_slug
    self.cached_slug = generate_slug
  end

  def generate_slug
    source = translated_name.presence || name
    SlugifyService.call(source)
  end
end
