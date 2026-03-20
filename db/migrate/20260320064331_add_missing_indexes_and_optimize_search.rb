class AddMissingIndexesAndOptimizeSearch < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    # Enable pg_trgm for fuzzy search
    enable_extension 'pg_trgm' unless extension_enabled?('pg_trgm')

    # Add missing indexes for boolean flags in products
    add_index :products, :is_new, algorithm: :concurrently unless index_exists?(:products, :is_new)
    add_index :products, :is_recommended, algorithm: :concurrently unless index_exists?(:products, :is_recommended)

    # Add index for status in orders
    add_index :orders, :status, algorithm: :concurrently unless index_exists?(:orders, :status)

    # Add GIN trgm indexes for fuzzy search in products
    add_index :products, :sku, using: :gist, opclass: :gist_trgm_ops, algorithm: :concurrently, name: 'index_products_on_sku_trgm' unless index_exists?(:products, nil, name: 'index_products_on_sku_trgm')
    add_index :products, :name, using: :gist, opclass: :gist_trgm_ops, algorithm: :concurrently, name: 'index_products_on_name_trgm' unless index_exists?(:products, nil, name: 'index_products_on_name_trgm')
    add_index :products, :name_ru, using: :gist, opclass: :gist_trgm_ops, algorithm: :concurrently, name: 'index_products_on_name_ru_trgm' unless index_exists?(:products, nil, name: 'index_products_on_name_ru_trgm')

    # Add index for categories.ikea_id if it doesn't exist (it should, but just in case)
    unless index_exists?(:categories, :ikea_id)
      add_index :categories, :ikea_id, unique: true, algorithm: :concurrently
    end
  end

  def down
    remove_index :products, name: 'index_products_on_sku_trgm' if index_exists?(:products, nil, name: 'index_products_on_sku_trgm')
    remove_index :products, name: 'index_products_on_name_trgm' if index_exists?(:products, nil, name: 'index_products_on_name_trgm')
    remove_index :products, name: 'index_products_on_name_ru_trgm' if index_exists?(:products, nil, name: 'index_products_on_name_ru_trgm')
    
    remove_index :orders, :status if index_exists?(:orders, :status)
    remove_index :products, :is_recommended if index_exists?(:products, :is_recommended)
    remove_index :products, :is_new if index_exists?(:products, :is_new)
    
    # disable_extension 'pg_trgm' # Not always safe to disable if other things use it
  end
end
