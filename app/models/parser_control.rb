# Виртуальная модель для админ-панели управления парсером
class ParserControl
  include ActiveModel::Model
  include ActiveModel::Attributes

  NEW_BACKGROUND_TASK_OPTIONS = [
    ["Полная актуализация категории / всего каталога", "refresh_category_catalog"]
  ].freeze

  NEW_BACKGROUND_TASK_TYPES = NEW_BACKGROUND_TASK_OPTIONS.map(&:last).freeze

  attribute :id, :string, default: 'show'

  def self.all
    [new(id: 'show')]
  end

  def self.find(id)
    new(id: id)
  end

  def self.new_background_task_type?(task_type)
    NEW_BACKGROUND_TASK_TYPES.include?(task_type.to_s)
  end

  def persisted?
    true
  end

  def to_param
    id
  end
end
