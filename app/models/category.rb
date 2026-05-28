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
  has_many :products_with_available_stock,
           -> { merge(Product.with_available_stock) },
           class_name: "Product",
           foreign_key: :category_id,
           primary_key: :ikea_id

  has_many :category_products, foreign_key: :category_id, primary_key: :ikea_id, dependent: :destroy
  has_many :products_through_categories, through: :category_products, source: :product
  has_many :product_filter_values, foreign_key: :category_id, primary_key: :ikea_id, dependent: :delete_all

  has_one :seo_meta, as: :seoable, class_name: "SeoMetum", dependent: :destroy
  accepts_nested_attributes_for :seo_meta, allow_destroy: true, update_only: true

  has_one :category_related_product_list,
          foreign_key: :category_id,
          primary_key: :ikea_id,
          dependent: :destroy,
          inverse_of: :category

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

  def catalog_url(categories_index = nil)
    segments = catalog_slug_path_segments(categories_index)
    return if segments.blank?

    "/catalog/#{segments.join('/')}/"
  end

  def catalog_slug_path_segments(categories_index = nil)
    ancestor_ids = self.class.normalize_parent_ids(parent_ids)
    segments = []

    if ancestor_ids.present?
      index = categories_index || self.class.where(ikea_id: ancestor_ids).index_by { |category| category.ikea_id.to_s }
      ancestor_ids.each do |ikea_id|
        slug_value = index[ikea_id.to_s]&.slug.presence
        segments << slug_value if slug_value.present?
      end
    end

    own_slug = slug.to_s.presence
    segments << own_slug if own_slug.present?

    segments.compact.uniq
  end

  def display_filters
    available_filters || []
  end

  def display_filters_for_api
    filters = normalize_filters(display_filters)
  
    filters.filter_map do |filter|
      param = filter["parameter"].to_s
      next if param.blank?
      next if param == "f-availability"
      next if param == "f-subcategories"
  
      if param == "f-price-buckets"
        build_price_filter_for_api(filter)
      else
        build_regular_filter_for_api(filter)
      end
    end
  end

  def current_category_price_range_byn
    products_scope = catalog_scope_for_filters_api.where.not(price: nil)
    return nil unless products_scope.exists?

    pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
    return nil if pln_rate.blank?

    buffer = CalculatorSetting.get('exchange_rate_buffer') || PriceCalculationService.exchange_rate_buffer

    prices_byn = []
    products_scope.find_in_batches(batch_size: 200) do |batch|
      batch.each do |product|
        pln_price = product.price.to_f
        next if pln_price <= 0

        prices_byn << PriceCalculationService.product_price_byn(
          pln_price,
          weight_kg: product.packaging_weight_kg.to_f,
          delivery_pln: product.delivery_cost.to_f,
          pln_rate: pln_rate,
          buffer: buffer
        )
      end
    end

    return nil if prices_byn.empty?

    {
      min: prices_byn.min,
      max: prices_byn.max
    }
  end

  # фильтры текущей категории + всех прямых дочерних
  def display_filters_with_children
    all_filters = normalize_filters(display_filters)
  
    direct_children.each do |child|
      all_filters.concat(normalize_filters(child.display_filters))
    end
  
    all_filters.uniq do |filter|
      next filter unless filter.is_a?(Hash)
  
      filter["parameter"].presence ||
        filter[:parameter].presence ||
        filter["name"].presence ||
        filter[:name].presence
    end
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

  # Текущая категория + все вложенные (для каталога API у родителя показываются товары потомков)
  def self_and_descendant_ikea_ids
    return [] if ikea_id.blank?

    [ikea_id.to_s, *descendant_ikea_ids].uniq
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

  def build_regular_filter_for_api(filter)
    param = filter["parameter"].to_s
  
    values = Array(filter["values"]).filter_map do |value|
      value = value.deep_stringify_keys
      value_id = value["id"].to_s
      next if value_id.blank?

      count = working_filter_value_count(param, value_id)
      next if count.zero?

      value.merge("count" => count)
    end

    if param == "f-series" && values.size > 1
      values = dedupe_f_series_values_for_api(values)
    end

    return nil if values.empty?

    filter.merge("values" => values)
  end

  def dedupe_f_series_values_for_api(values)
    values
      .group_by { |v| Products::SeriesFilterNormalization.normalize_key(v["name"].presence || v["id"]) }
      .reject { |k, _| k.blank? }
      .map do |_key, rows|
        canonical = Products::SeriesFilterNormalization.pick_canonical_value_row(rows)
        ids = rows.map { |r| r["id"].to_s }.reject(&:blank?).uniq
        count =
          if rows.one?
            rows.first["count"].to_i
          else
            working_filter_value_count_distinct_products("f-series", ids)
          end
        canonical.merge("count" => count)
      end
      .sort_by { |v| (v["name"].presence || v["id"]).to_s.mb_chars.downcase.to_s }
  end

  def build_price_filter_for_api(filter)
    price_range = current_category_price_range_byn
    return nil if price_range.blank?

    products_count = catalog_scope_for_filters_api.where.not(price: nil).distinct.count
    return nil if products_count.zero?
  
    filter.merge(
      "values" => [{
        "id" => "PRICE_RANGE",
        "name" => "#{format_byn_amount(price_range[:min])} - #{format_byn_amount(price_range[:max])} BYN",
        "min" => price_range[:min],
        "max" => price_range[:max],
        "count" => products_count
      }]
    )
  end
  
  def working_filter_value_count(parameter, value_id)
    ProductFilterValue
      .where(category_id: catalog_filter_tree_ikea_ids, parameter: parameter.to_s, value_id: value_id.to_s)
      .joins(:product)
      .merge(Product.with_available_stock)
      .distinct
      .count(:product_id)
  end

  def working_filter_value_count_distinct_products(parameter, value_ids)
    ProductFilterValue
      .where(category_id: catalog_filter_tree_ikea_ids, parameter: parameter.to_s, value_id: value_ids)
      .joins(:product)
      .merge(Product.with_available_stock)
      .distinct
      .count(:product_id)
  end

  # Товары и product_filter_values для API-фильтров: текущая категория + потомки
  # (как в Products::SearchService#initial_scope).
  def catalog_scope_for_filters_api
    Product.in_categories_ikea_ids(catalog_filter_tree_ikea_ids).active.with_available_stock
  end

  def catalog_filter_tree_ikea_ids
    @catalog_filter_tree_ikea_ids ||= self_and_descendant_ikea_ids
  end

  def price_bucket_name_in_byn(value_id, eur_rate)
    return nil if eur_rate.blank?
  
    match = value_id.to_s.match(/\APRICE_(\d+)_(\d+)\z/)
    return nil unless match
  
    from_cents = match[1].to_i
    to_cents   = match[2].to_i
  
    from_eur = from_cents / 100.0
  
    if huge_upper_bound?(to_cents)
      from_byn = from_eur * eur_rate
      "#{format_byn_amount(from_byn)}+ BYN"
    else
      to_eur = (to_cents - 1) / 100.0
      from_byn = from_eur * eur_rate
      to_byn   = to_eur * eur_rate
  
      "#{format_byn_amount(from_byn)} - #{format_byn_amount(to_byn)} BYN"
    end
  end

  def huge_upper_bound?(value)
    value >= 9_223_372_036_854_775_807
  end
  
  def format_byn_amount(amount)
    format('%.2f', amount.round(2)).tr('.', ',')
  end

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
