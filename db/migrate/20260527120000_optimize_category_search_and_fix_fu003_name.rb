class OptimizeCategorySearchAndFixFu003Name < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    unless index_exists?(:categories, nil, name: "index_categories_on_translated_name_trgm")
      add_index :categories,
                :translated_name,
                using: :gist,
                opclass: :gist_trgm_ops,
                algorithm: :concurrently,
                name: "index_categories_on_translated_name_trgm"
    end

    unless index_exists?(:categories, nil, name: "index_categories_on_name_trgm")
      add_index :categories,
                :name,
                using: :gist,
                opclass: :gist_trgm_ops,
                algorithm: :concurrently,
                name: "index_categories_on_name_trgm"
    end

    # В проде translated_name был «Раскладные диваны» при польском name «nierozkładane».
    execute <<~SQL.squish
      UPDATE categories
      SET translated_name = 'Диваны нераскладные', updated_at = CURRENT_TIMESTAMP
      WHERE ikea_id = 'fu003'
        AND (translated_name IS NULL OR translated_name ILIKE '%раскладные%')
    SQL
  end

  def down
    remove_index :categories, name: "index_categories_on_translated_name_trgm", algorithm: :concurrently, if_exists: true
    remove_index :categories, name: "index_categories_on_name_trgm", algorithm: :concurrently, if_exists: true
  end
end
