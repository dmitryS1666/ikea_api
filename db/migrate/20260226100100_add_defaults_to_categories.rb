class AddDefaultsToCategories < ActiveRecord::Migration[7.1]
  def change
    change_column_default :categories, :is_top, from: nil, to: false
    change_column_default :categories, :top_position, from: nil, to: 0
    change_column_default :categories, :is_custom, from: nil, to: false
    
    # Update existing records
    Category.update_all(is_top: false, top_position: 0, is_custom: false)
  end
end
