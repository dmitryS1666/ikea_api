class AddIncludedProductsToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :included_products, :text
  end
end
