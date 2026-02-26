class DropRecommendedProductsTable < ActiveRecord::Migration[7.1]
  def change
    drop_table :recommended_products
  end
end
