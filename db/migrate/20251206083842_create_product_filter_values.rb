class CreateProductFilterValues < ActiveRecord::Migration[7.1]
  def change
    create_table :product_filter_values do |t|
      t.references :product, null: false, foreign_key: true
      t.references :filter_value, null: false, foreign_key: true

      t.timestamps
    end
  end
end
