class RecreateProductFilterValues < ActiveRecord::Migration[7.1]
  def change
    create_table :product_filter_values do |t|
      t.bigint :product_id, null: false
      t.string :category_id, null: false
      t.string :parameter, null: false
      t.string :value_id, null: false
      t.timestamps
    end

    add_index :product_filter_values, [:category_id, :parameter, :value_id, :product_id],
              name: "index_product_filter_values_on_category_param_value_product"
    add_index :product_filter_values, [:product_id, :category_id],
              name: "index_product_filter_values_on_product_and_category"
    add_index :product_filter_values, [:product_id, :category_id, :parameter, :value_id],
              unique: true,
              name: "index_product_filter_values_unique"

    add_foreign_key :product_filter_values, :products
    add_foreign_key :product_filter_values, :categories, column: :category_id, primary_key: :ikea_id
  end
end
