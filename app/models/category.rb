class Category < ApplicationRecord
  self.primary_key = 'ikea_id'
  
  validates :ikea_id, presence: true, uniqueness: true
  validates :name, presence: true
  
  has_many :products, foreign_key: :category_id, primary_key: :ikea_id
  
  serialize :parent_ids, coder: JSON
  
  scope :popular, -> { where(is_popular: true) }
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
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
  def children_count
    return 0 unless ikea_id.present?
    
    # parent_ids хранится в БД как JSON текст (например: '["id1", "id2"]')
    # После deserialize это массив Ruby
    # Ищем категории, у которых в parent_ids содержится ikea_id текущей категории
    
    # Используем PostgreSQL JSON операторы для поиска в JSON массиве
    # Вариант 1: JSON содержит элемент (для JSONB)
    # Вариант 2: LIKE для текстового поиска (для TEXT с JSON)
    Category.where(
      "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
      "%\"#{ikea_id}\"%",  # JSON массив: ["parent_id"]
      "%#{ikea_id}%"      # Путь: "parent_id/child_id" или просто строка
    ).where.not(ikea_id: ikea_id) # Исключаем саму категорию
     .count
  end
end
