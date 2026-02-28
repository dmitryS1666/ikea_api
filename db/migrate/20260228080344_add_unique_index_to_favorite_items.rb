class AddUniqueIndexToFavoriteItems < ActiveRecord::Migration[7.1]
  def change
    add_index :favorite_items, [:favorite_id, :product_sku], unique: true
  end
end
