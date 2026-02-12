class AddSortingToCategoriesAndPopularityToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :default_sort, :string, default: 'popular'
    add_column :products, :popularity_score, :integer, default: 0
    add_column :products, :views_count, :integer, default: 0
    add_column :products, :sales_count, :integer, default: 0
    
    add_index :categories, :default_sort
    add_index :products, :popularity_score
    add_index :products, :views_count
    add_index :products, :price
  end
end
