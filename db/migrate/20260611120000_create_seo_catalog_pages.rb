class CreateSeoCatalogPages < ActiveRecord::Migration[7.1]
  def change
    create_table :seo_catalog_pages do |t|
      t.string :slug, null: false
      t.string :title
      t.string :h1
      t.string :meta_title
      t.string :meta_description
      t.text :seo_text
      t.string :canonical_path
      t.integer :status, null: false, default: 0
      t.boolean :indexable, null: false, default: true
      t.integer :position, null: false, default: 0
      t.jsonb :filter_config, null: false, default: {}
      t.jsonb :products_snapshot, null: false, default: []
      t.integer :products_count, null: false, default: 0
      t.datetime :last_generated_at
      t.datetime :last_products_updated_at
      t.datetime :published_at

      t.timestamps
    end

    add_index :seo_catalog_pages, :slug, unique: true
    add_index :seo_catalog_pages, :status
    add_index :seo_catalog_pages, [:status, :indexable, :products_count], name: "index_seo_catalog_pages_for_sitemap"
    add_index :seo_catalog_pages, :position
    add_index :seo_catalog_pages, :filter_config, using: :gin
  end
end
