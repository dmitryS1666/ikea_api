class AddSlugToCategoriesAndProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :cached_slug, :string
    add_column :products, :cached_slug, :string
    
    add_index :categories, :cached_slug
    add_index :products, :cached_slug
  end
end
