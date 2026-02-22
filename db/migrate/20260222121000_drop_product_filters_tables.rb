class DropProductFiltersTables < ActiveRecord::Migration[7.1]
  def change
    drop_table :product_filter_values, if_exists: true
    drop_table :filter_values, if_exists: true
    drop_table :filters, if_exists: true
  end
end
