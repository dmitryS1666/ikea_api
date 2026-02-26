class AddTopAndCustomFieldsToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :is_top, :boolean
    add_column :categories, :top_position, :integer
    add_column :categories, :is_custom, :boolean
  end
end
