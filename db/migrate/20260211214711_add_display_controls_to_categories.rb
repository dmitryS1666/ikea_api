class AddDisplayControlsToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :is_bulky, :boolean, default: false
    add_column :categories, :show_delivery_block, :boolean, default: true
    add_column :categories, :show_reviews_block, :boolean, default: true
    add_column :categories, :show_tips_block, :boolean, default: true
  end
end
