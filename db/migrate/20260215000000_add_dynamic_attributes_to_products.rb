class AddDynamicAttributesToProducts < ActiveRecord::Migration[7.1]
  def change
    # Основные атрибуты из JSONL
    add_column :products, :full_attributes, :jsonb, default: {}
    
    # Дополнительные поля, которые часто встречаются
    add_column :products, :packaging, :jsonb, default: {}
    
    # Русские переводы для новых полей
    add_column :products, :full_attributes_ru, :jsonb, default: {}

    # dimensions уже есть как string, оставим его пока, 
    # но в импорте будем писать туда строку или JSON если модель позволяет
  end
end
