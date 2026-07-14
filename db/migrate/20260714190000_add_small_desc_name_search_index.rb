# frozen_string_literal: true

class AddSmallDescNameSearchIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_products_on_small_desc_name_trgm"

  def up
    enable_extension("pg_trgm") unless extension_enabled?("pg_trgm")

    return if index_exists?(:products, nil, name: INDEX_NAME)

    add_index :products,
              :small_desc_name,
              using: :gin,
              opclass: :gin_trgm_ops,
              algorithm: :concurrently,
              name: INDEX_NAME
  end

  def down
    return unless index_exists?(:products, nil, name: INDEX_NAME)

    remove_index :products, name: INDEX_NAME, algorithm: :concurrently
  end
end
