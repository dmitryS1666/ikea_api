class AddWebpayPaymentFieldsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :payment_link_token, :string
    add_column :orders, :payment_order_number, :string

    add_index :orders, :payment_link_token, unique: true
  end
end
