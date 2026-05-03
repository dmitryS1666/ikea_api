# frozen_string_literal: true

class CreateCategoryRelatedProductLists < ActiveRecord::Migration[7.1]
  def change
    create_table :category_related_product_lists do |t|
      t.string :category_id, null: false
      t.jsonb :related_products, null: false, default: []
      t.string :anchor_first_sku
      t.string :anchor_last_sku
      t.timestamps
    end

    add_index :category_related_product_lists, :category_id, unique: true
    add_foreign_key :category_related_product_lists, :categories, column: :category_id, primary_key: :ikea_id
  end
end
