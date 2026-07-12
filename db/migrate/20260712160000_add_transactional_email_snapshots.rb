# frozen_string_literal: true

class AddTransactionalEmailSnapshots < ActiveRecord::Migration[7.1]
  def up
    add_column :orders, :pricing_snapshot, :jsonb, default: {}, null: false
    add_column :order_items, :name_snapshot, :text
    add_column :order_items, :description_snapshot, :text

    execute <<~SQL.squish
      UPDATE order_items
      SET
        name_snapshot = product_sku,
        description_snapshot = ''
      WHERE name_snapshot IS NULL OR description_snapshot IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE order_items AS oi
      SET
        name_snapshot = COALESCE(
          NULLIF(products.small_desc_name, ''),
          NULLIF(products.name_ru, ''),
          NULLIF(products.name, ''),
          oi.product_sku
        ),
        description_snapshot = COALESCE(
          NULLIF(products.dimensions_ru, ''),
          NULLIF(products.dimensions, ''),
          ''
        )
      FROM products
      WHERE products.sku = oi.product_sku
    SQL
  end

  def down
    remove_column :order_items, :description_snapshot
    remove_column :order_items, :name_snapshot
    remove_column :orders, :pricing_snapshot
  end
end
