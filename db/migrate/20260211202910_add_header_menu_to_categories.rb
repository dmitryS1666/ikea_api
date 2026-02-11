class AddHeaderMenuToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :header_menu, :boolean
    add_column :categories, :header_menu_position, :integer
  end
end
