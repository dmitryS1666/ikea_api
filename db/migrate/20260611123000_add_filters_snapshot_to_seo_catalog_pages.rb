class AddFiltersSnapshotToSeoCatalogPages < ActiveRecord::Migration[7.1]
  def change
    add_column :seo_catalog_pages, :filters_snapshot, :jsonb, null: false, default: []
    add_index :seo_catalog_pages, :filters_snapshot, using: :gin
  end
end
