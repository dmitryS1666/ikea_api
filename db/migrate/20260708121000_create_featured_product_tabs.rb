class CreateFeaturedProductTabs < ActiveRecord::Migration[7.1]
  def change
    create_table :featured_product_tabs do |t|
      t.string :list_key, null: false
      t.string :category_id, null: false
      t.jsonb :product_skus, default: [], null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :featured_product_tabs, [:list_key, :position]
    add_index :featured_product_tabs, :category_id
    add_index :featured_product_tabs, :active
  end
end
