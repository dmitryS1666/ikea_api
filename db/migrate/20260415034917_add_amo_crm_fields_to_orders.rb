class AddAmoCrmFieldsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :weight, :decimal
    add_column :orders, :cancellation_reason, :text
  end
end
