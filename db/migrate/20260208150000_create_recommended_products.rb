class CreateRecommendedProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :recommended_products do |t|
      t.string :product_sku, null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :recommended_products, :product_sku, unique: true
    add_index :recommended_products, [:active, :position]
  end
end
