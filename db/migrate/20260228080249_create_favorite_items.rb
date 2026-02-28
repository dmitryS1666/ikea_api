class CreateFavoriteItems < ActiveRecord::Migration[7.1]
  def change
    create_table :favorite_items do |t|
      t.references :favorite, null: false, foreign_key: true
      t.string :product_sku

      t.timestamps
    end
    add_index :favorite_items, :product_sku
  end
end
