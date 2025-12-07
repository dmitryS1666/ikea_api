class AddIndexes < ActiveRecord::Migration[7.1]
  def change
    # Products
    add_index :products, :sku, unique: true
    add_index :products, :unique_id, unique: true, where: "unique_id IS NOT NULL"
    add_index :products, :category_id
    add_index :products, :is_bestseller
    add_index :products, :is_popular
    add_index :products, :updated_at
    
    # Categories
    add_index :categories, :ikea_id, unique: true
    add_index :categories, :unique_id, unique: true, where: "unique_id IS NOT NULL"
    add_index :categories, :is_popular
    
    # Filters
    add_index :filters, :parameter, unique: true
    
    # FilterValues
    add_index :filter_values, :value_id, unique: true
    add_index :filter_values, :filter_id
    
    # Users
    add_index :users, :username, unique: true
    add_index :users, :email, unique: true, where: "email IS NOT NULL"
  end
end
