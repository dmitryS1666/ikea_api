# frozen_string_literal: true

class CreateCategoryRelatedProductLists < ActiveRecord::Migration[7.1]
  def up
    unless table_exists?(:category_related_product_lists)
      create_table :category_related_product_lists do |t|
        t.string :category_id, null: false
        t.jsonb :related_products, null: false, default: []
        t.string :anchor_first_sku
        t.string :anchor_last_sku
        t.timestamps
      end
    end

    unless index_exists?(:category_related_product_lists, :category_id, unique: true)
      add_index :category_related_product_lists, :category_id, unique: true
    end

    unless foreign_key_exists?(:category_related_product_lists, :categories, column: :category_id)
      add_foreign_key :category_related_product_lists, :categories, column: :category_id, primary_key: :ikea_id
    end
  end

  def down
    drop_table :category_related_product_lists, if_exists: true
  end
end
