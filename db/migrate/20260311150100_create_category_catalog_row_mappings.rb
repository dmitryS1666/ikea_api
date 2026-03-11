class CreateCategoryCatalogRowMappings < ActiveRecord::Migration[7.1]
  def change
    create_table :category_catalog_row_mappings do |t|
      t.integer :row_no, null: false
      t.string  :ikea_id
      t.string  :matched_by
      t.decimal :confidence, precision: 5, scale: 2, default: 0.0, null: false

      t.string  :raw_name
      t.string  :seo_name
      t.text    :path
      t.integer :depth

      t.jsonb   :meta, null: false, default: {}

      t.timestamps
    end

    add_index :category_catalog_row_mappings, :row_no, unique: true
    add_index :category_catalog_row_mappings, :ikea_id
  end
end
