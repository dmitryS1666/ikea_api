class Category < ApplicationRecord
  self.primary_key = 'ikea_id'
  
  has_one_attached :icon
  has_one_attached :pictogram
  has_one_attached :background_image
  
  validates :ikea_id, presence: true, uniqueness: true
  validates :name, presence: true
  
  # Старая связь (для обратной совместимости, будет удалена после миграции)
  has_many :products, foreign_key: :category_id, primary_key: :ikea_id
  
  # Новая связь many-to-many
  has_many :category_products, foreign_key: :category_id, primary_key: :ikea_id, dependent: :destroy
  has_many :products_through_categories, through: :category_products, source: :product
  has_many :product_filter_values, foreign_key: :category_id, primary_key: :ikea_id, dependent: :delete_all
  
  has_one :seo_meta, as: :seoable, class_name: 'SeoMetum', dependent: :destroy
  accepts_nested_attributes_for :seo_meta, allow_destroy: true, update_only: true
  
  serialize :parent_ids, coder: JSON
  
  before_save :cache_slug, if: -> { name_changed? || translated_name_changed? || cached_slug.blank? }

  enum :default_sort, {
    popular: 'popular',
    newest: 'newest',
    cheapest: 'cheapest',
    expensive: 'expensive'
  }

  def slug
    cached_slug || generate_slug
  end

  scope :top, -> { where(is_top: true).order(top_position: :asc) }
  scope :popular, -> { where(is_popular: true) }
  scope :custom, -> { where(is_custom: true) }
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  
  def display_filters
    available_filters_ru.presence || available_filters || []
  end

  private

  def cache_slug
    self.cached_slug = generate_slug
  end

  def generate_slug
    source = translated_name.presence || name
    SlugifyService.call(source)
  end

  # Категории с цифровым кодом (ikea_id состоит только из цифр)
  scope :with_numeric_id, -> { where("ikea_id ~ '^[0-9]+$'") }
  # Верхнеуровневые категории (без родительских категорий)
  # Используем поле is_important для определения верхнеуровневых категорий
  # Также проверяем parent_ids на nil или пустой массив для совместимости
  scope :top_level, -> {
    where(
      "is_important = ? OR parent_ids IS NULL OR parent_ids::text = ? OR parent_ids::text = ? OR parent_ids::text = ?",
      true, '[]', '""', ''
    )
  }
  
  # Подсчет дочерних категорий (категории, у которых текущая категория в parent_ids)
  # Кэшируем результат для каждой категории
  def children_count
    return 0 unless ikea_id.present?
    
    Rails.cache.fetch("category_#{ikea_id}_children_count", expires_in: 30.minutes) do
      # Оптимизированный запрос - используем только COUNT без загрузки записей
      Category.where(
        "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
        "%\"#{ikea_id}\"%",  # JSON массив: ["parent_id"]
        "%#{ikea_id}%"      # Путь: "parent_id/child_id" или просто строка
      ).where.not(ikea_id: ikea_id) # Исключаем саму категорию
       .count
    end
  end

  # Получить дочерние категории
  def children
    return Category.none unless ikea_id.present?
    
    # Оптимизированный запрос - загружаем только нужные поля
    Category.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_deleted, :is_important)
            .where(
              "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
              "%\"#{ikea_id}\"%",
              "%#{ikea_id}%"
            )
            .where.not(ikea_id: ikea_id)
            .order(:name)
  end

  # Проверка, является ли категория родительской (имеет дочерние)
  def has_children?
    children_count > 0
  end

  # Проверка наличия продуктов в категории
  def has_products?
    products.exists?
  end

  # Проверка, является ли ID категории числовым
  def numeric_id?
    ikea_id.to_s.match?(/^\d+$/)
  end

  # Проверка, является ли ID категории UUID
  def uuid_id?
    ikea_id.to_s.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  # Класс для построения дерева категорий
  class << self
    def build_tree(categories = nil)
      categories ||= Category.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_top, :top_position, :is_custom, :is_deleted, :is_important)
                             .order(:name)
                             .to_a
      
      # Создаем быстрый поиск по ID для проверки наличия родителей в наборе
      category_ids = categories.map { |c| c.ikea_id.to_s }.to_set
      
      # Оптимизация: создаем индекс для быстрого поиска дочерних категорий
      children_index = {}
      categories.each do |cat|
        parent_ids = self.normalize_parent_ids(cat.parent_ids)
        next unless parent_ids.present? && parent_ids.any?
        
        parent_ids.each do |parent_id|
          parent_key = parent_id.to_s
          children_index[parent_key] ||= []
          children_index[parent_key] << cat
        end
      end
      
      # Находим верхнеуровневые категории ДЛЯ ДАННОГО НАБОРА
      # Категория считается корневой, если:
      # 1. Она помечена как is_important
      # 2. У нее нет родителей
      # 3. Ни один из ее родителей не представлен в текущем наборе (важно для фильтров типа "ТОП")
      top_level = categories.select do |c|
        parent_ids = self.normalize_parent_ids(c.parent_ids)
        
        # Категория считается корневой, если:
        # 1. Она помечена как is_important
        # 2. У нее нет родителей
        # 3. Ни один из ее родителей не представлен в текущем наборе (важно для фильтров типа "ТОП")
        c.is_important || 
          parent_ids.blank? || 
          parent_ids.none? { |pid| category_ids.include?(pid.to_s) }
      end
      
      build_tree_recursive(top_level, children_index)
    end

    # Публичный метод для нормализации parent_ids (используется в контроллерах)
    def normalize_parent_ids(parent_ids)
      return [] if parent_ids.blank?
      
      # Если это уже массив, возвращаем как есть
      return parent_ids if parent_ids.is_a?(Array)
      
      # Если это строка JSON, парсим
      if parent_ids.is_a?(String)
        begin
          parsed = JSON.parse(parent_ids)
          return parsed if parsed.is_a?(Array)
          return [parsed] if parsed.present?
        rescue JSON::ParserError
          # Если не JSON, пробуем как простую строку
          return [parent_ids] if parent_ids.present?
        end
      end
      
      []
    end

    private

    def build_tree_recursive(parents, children_index, visited = [])
      parents.map do |parent|
        parent_id = parent.ikea_id.to_s
        
        # Предотвращаем бесконечную рекурсию при наличии циклов в данных
        if visited.include?(parent_id)
          Rails.logger.warn "Circular dependency detected for category #{parent_id}. Skipping children."
          next {
            category: parent,
            children: []
          }
        end
        
        # Используем индекс для быстрого поиска дочерних категорий
        children = children_index[parent_id] || []
        
        {
          category: parent,
          children: build_tree_recursive(children, children_index, visited + [parent_id])
        }
      end
    end
  end
end
